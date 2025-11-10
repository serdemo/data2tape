#!/bin/bash
# Version: 1.0.1
#
# CAUTION: To avoid data loss don't use this script with libraries managed by another backup software. Use a separate library with a separate scratch tapes pool.
#
# Description:
# This script helps automate offsite tape backups.
# It will automatically select a drive and a tape to write a single given directory and all of its contents or a single given file to a tape, then export the tape to a free IO slot.
# Required configuration files
# - ./cfg/lib.cfg: LIB_X_${SITE};LIB_SERIAL;ACCESS(ALLOW|DENY)
# - ./cfg/drive.cfg: DRIVE_X_${SITE};DRIVE_SERIAL;ACCESS(ALLOW|DENY)
# Command example: ./data2tape.sh site1 /directory "Archive description"
# Prerequisites:
# - ITDT utility: https://datacentersupport.lenovo.com/us/en/products/storage/tape-and-backup/ts4300-tape-library-for-lenovo/6741/downloads/driver-list/component?name=Software%20and%20Utilities&id=156BE23F-B536-4320-B35C-2F67EBDD9242
# - lin_tape driver: https://datacentersupport.lenovo.com/us/en/products/storage/tape-and-backup/ts4300-tape-library-for-lenovo/6741/downloads/driver-list/component?name=Software%20and%20Utilities&id=156BE23F-B536-4320-B35C-2F67EBDD9242
# - IBM/Lenovo tape library
# Test environment: REDOS 7.3, kernel: 5.15.131-1.el7.3.x86_64, driver: lin_tape v3.0.59, ITDT v9.6.2.20231114, Tape library: TS4300 Type 6741

# check required binary executables
exit_code=0
exec_type=type # shell built-in
exec_grep=$(${exec_type} -P grep 2>/dev/null) || exit_code=1
exec_date=$(${exec_type} -P date 2>/dev/null) || exit_code=1
exec_itdt=$(${exec_type} -P itdt 2>/dev/null) || exit_code=1
exec_tar=$(${exec_type} -P tar 2>/dev/null) || exit_code=1
exec_sed=$(${exec_type} -P sed 2>/dev/null) || exit_code=1
exec_awk=$(${exec_type} -P awk 2>/dev/null) || exit_code=1
exec_cat=$(${exec_type} -P cat 2>/dev/null) || exit_code=1
exec_tr=$(${exec_type} -P tr 2>/dev/null) || exit_code=1
exec_mv=$(${exec_type} -P mv 2>/dev/null) || exit_code=1
exec_ls=$(${exec_type} -P ls 2>/dev/null) || exit_code=1
exec_xargs=$(${exec_type} -P xargs 2>/dev/null) || exit_code=1
exec_touch=$(${exec_type} -P touch 2>/dev/null) || exit_code=1
exec_mkdir=$(${exec_type} -P mkdir 2>/dev/null) || exit_code=1
exec_dirname=$(${exec_type} -P dirname 2>/dev/null) || exit_code=1
exec_basename=$(${exec_type} -P basename 2>/dev/null) || exit_code=1
[[ ${exit_code} -ne 0 ]] \
        && msg="ERROR (rc ${exit_code}): check that the following programs are installed: grep date itdt tar sed awk cat tr mv ls xargs touch mkdir dirname basename" \
        && echo "$msg" && exit $exit_code

# script's path variables
SCRIPTN="$(${exec_basename} $0)"
SCRIPTD="$(${exec_dirname} -- "${BASH_SOURCE[0]}")"

# script's directory structure
tmp_dir=${SCRIPTD}/tmp
log_dir=${SCRIPTD}/log
cfg_dir=${SCRIPTD}/cfg
db_dir=${SCRIPTD}/db

[[ ! -d ${tmp_dir} ]] && ${exec_mkdir} -p ${tmp_dir} 2>/dev/null
[[ ! -d ${log_dir} ]] && ${exec_mkdir} -p ${log_dir} 2>/dev/null
[[ ! -d ${cfg_dir} ]] && ${exec_mkdir} -p ${cfg_dir} 2>/dev/null
[[ ! -d ${db_dir} ]] && ${exec_mkdir} -p ${db_dir} 2>/dev/null
[[ ! -d ${tmp_dir} || ! -d ${log_dir} || ! -d ${cfg_dir} || ! -d ${db_dir} ]] && exit_code=2 

# variables for logging and error handling
LD=$(${exec_date} +'%Y%m%d')
log_file=${log_dir}/${SCRIPTN}.log
backup_ok="no" # initial state of backup task

# configuration variables and arguments
[[ -f ${SCRIPTD}/cfg/lib.cfg ]] && lib_cfg=${SCRIPTD}/cfg/lib.cfg || exit_code=3
[[ -f ${SCRIPTD}/cfg/drive.cfg ]] && drv_cfg=${SCRIPTD}/cfg/drive.cfg || exit_code=4
[[ -n "${3}" ]] && optional_description=" \"${3}\"" || optional_description=""
[[ -d "${2}" || -f "${2}" ]] && data2bak="${2}" || exit_code=6
[[ "${1,,}" =~ gvc|rvc ]] && site="${1,,}" || exit_code=5
ok_if_empty="no" # set to yes if you need to write empty dirs to tape
dirtydb_ok="yes" # do not change; the variable is used in update_dirtydb function

# device variables and flags
access="ALLOW"             # select only those items from inventory which are marked by 'ALLOW' flag
cln_tapes="CLNU"           # set identificator of cleaning tapes so they are filtered out from scipt's logic
dev_tape=/dev/IBMtape      # set tape device class name
dev_libr=/dev/IBMchanger   # set library changer device class name
lib_found=0                # initial library detection flag
drv_found=0                # initial drive detection flag

# text database variables
inventory_file=${db_dir}/inventory_${site}
dirty_tapes=${db_dir}/dirty_tapes_${site}
tape_content=${db_dir}/tape_content_${LD}
backups_journal=${db_dir}/offsite_backup_journal_${site}


# Functions

usage() {
        echo "Script usage: ./${SCRIPTN} [gvc|rvc] [path to file or directory] [\"optional description\"]"
}

err_msg() {

        case "$exit_code" in
                1 )
                        msg="ERROR (rc ${exit_code}): check that the following programs are installed: \
				grep date itdt tar sed awk cat tr mv ls xargs touch mkdir dirname basename"
                        write_log "$msg"
                        echo "$msg" | ${exec_xargs}
                        exit $exit_code
                        ;;
		2 )
                        msg="ERROR (rc ${exit_code}): failed to create required directory structure. Check permissions."
                        write_log "$msg"
                        echo "$msg"
                        exit $exit_code
                        ;;
                3 )
                        msg="ERROR (rc ${exit_code}): library configuration file is missing: ${SCRIPTN}/cfg/lib.cfg"
                        write_log "$msg"
                        echo "$msg"
                        exit $exit_code
                        ;;
                4 )
                        msg="ERROR (rc ${exit_code}): drives configuration file is missing: ${SCRIPTN}/cfg/drive.cfg"
                        write_log "$msg"
                        echo "$msg"
                        exit $exit_code
                        ;;
                5 )
                        msg="ERROR (rc ${exit_code}): provide site as first argument. Names of sites can be configured in 'configuration variables and arguments' section of this script"
                        write_log "$msg"
                        echo "$msg"
                        usage
                        exit $exit_code
                        ;;
                6 )
                        msg="ERROR (rc ${exit_code}): please provide working path to file or directory you want to backup to tape as 2nd argument"
                        write_log "$msg"
                        echo "$msg"
                        usage
                        exit $exit_code
                        ;;
                7 )
                        msg="ERROR (rc ${exit_code}): can't find or match library serial number for site: $site in config: $lib_cfg"
                        write_log "$msg"
                        echo "$msg"
                        exit $exit_code
                        ;;
                8 )
                        msg="ERROR (rc ${exit_code}): can't find ${dev_libr}*"
                        write_log "$msg"
                        echo "$msg"
                        exit $exit_code
                        ;;
                9 )
                        msg="ERROR (rc ${exit_code}): access denied writing log file $log_file"
                        #write_log "$msg"
                        echo "$msg"
                        #exit $exit_code
                        ;;
                10 )
                        msg="ERROR (rc ${exit_code}): access denied writing file $inventory_file"
                        write_log "$msg"
                        echo "$msg"
                        exit $exit_code
                        ;;
                11 )
                        msg="ERROR (rc ${exit_code}): getting inventory from ITDT utility"
                        write_log "$msg"
                        echo "$msg"
                        exit $exit_code
                        ;;
                12 )
                        msg="ERROR (rc ${exit_code}): tapes or slots array is empty"
                        write_log "$msg"
                        echo "$msg"
                        exit $exit_code
                        ;;
                13 )
                        msg="ERROR (rc ${exit_code}): all drives are busy. Try again later"
                        write_log "$msg"
                        echo "$msg"
                        exit $exit_code
                        ;;
                14 )
                        msg="ERROR (rc ${exit_code}): can't detect available drives in config: $drv_cfg. Check configuration syntax: DRIVE_X_SITE;SERIAL;ACCESS(ALLOW|DENY)"
                        write_log "$msg"
                        echo "$msg"
                        exit $exit_code
                        ;;
                15 )
                        msg="ERROR (rc ${exit_code}): can't detect serial number for drive $drv_num at site $site"
                        write_log "$msg"
                        echo "$msg"
                        exit $exit_code
                        ;;
                16 )
                        msg="ERROR (rc ${exit_code}): system tape device ${dev_tape}* serial could not be matched with inventory drive $drv_num at site $site"
                        write_log "$msg"
                        echo "$msg"
                        exit $exit_code
                        ;;
                17 )
                        msg="ERROR (rc ${exit_code}): system tape device ${dev_tape}* was not found"
                        write_log "$msg"
                        echo "$msg"
                        exit $exit_code
                        ;;
                18 )
                        msg="ERROR (rc ${exit_code}): unable to mount tape $tape_id from slot $slot_id to drive $drive_name (${drive_dev})"
                        write_log "$msg"
                        echo "$msg"
                        exit $exit_code
                        ;;
                19 )
                        msg="ERROR (rc ${exit_code}): provided data source is empty or inaccessible - ${data2bak}"
                        write_log "$msg"
                        echo "$msg"
                        exit $exit_code
                        ;;
                20 )
                        msg="ERROR (rc ${exit_code}): failed to write data to tape $tape_id in drive $drive_name (${drive_dev})"
                        write_log "$msg"
                        echo "$msg"
                        exit $exit_code
                        ;;
                21 )
                        msg="ERROR (rc ${exit_code}): $err_msg_21"
                        write_log "$msg"
                        echo "$msg"
                        #exit $exit_code
                        ;;
                22 )
                        msg="ERROR (rc ${exit_code}): $err_msg_22"
                        write_log "$msg"
                        echo "$msg"
                        #exit $exit_code
                        ;;
                0 )
                        exit $exit_code
                        ;;
                * )
                        msg="ERROR (rc ?): unknown error"
                        write_log "$msg"
                        echo "$msg"
                        exit 99
                        ;;
        esac

}

write_log() {
        msg=$@
        LDT=$(${exec_date} +"%Y-%m-%d %T")
        if [[ ! -f "$log_file" ]]; then
               ${exec_touch} "$log_file" 2>/dev/null || exit_code=9
               [[ $exit_code -ne 0 ]] && err_msg
        fi
        while IFS= read -r line; do
                [[ -n $line ]] && echo -e "${LDT} ${line}" >> $log_file
                LDT=$(${exec_date} +"%Y-%m-%d %T")
        done <<< "$msg"
}

check_datasource() {
        # check if data is not empty
        is_datatype=$(if [[ -d "${data2bak}" ]]; then echo "directory"; elif [[ -f "${data2bak}" ]]; then echo "file"; else echo "nodata"; fi)
        [[ "$is_datatype" == "directory" ]] && files_cnt=$(find ${data2bak} -type f 2>/dev/null | wc -l)
        [[ "$is_datatype" == "directory" && ${files_cnt} -eq 0 ]] && is_datatype="empty"
        [[ "${is_datatype}" == "empty" && "${ok_if_empty}" == "no" || "${is_datatype}" == "nodata" ]] && exit_code=19 && err_msg
}

get_lib() {
        ${exec_ls} -ls ${dev_libr}* >/dev/null 2>&1
        if [[ $? -eq 0 ]]; then
                lib_serial=$(${exec_cat} "$lib_cfg" | ${exec_grep} -v '#' | ${exec_grep} -i "$site" | ${exec_grep} "$access" | ${exec_awk} -F';' '{print $2}')
                [[ -z "$lib_serial" ]] && exit_code=7 && err_msg
                for i in $(${exec_ls} -ls ${dev_libr}* 2>/dev/null | ${exec_awk} '{print $NF}'); do
                        dev_serial=$(udevadm info --attribute-walk ${i} 2>/dev/null | ${exec_grep} -i 'serial' | ${exec_awk} -F'==' '{print $2}' | ${exec_tr} -d '"')
                        if [[ "$lib_serial" == "$dev_serial" ]]; then
                                # set selected library
                                libr=$i
                                write_log "INFO: selected library: $libr (${lib_serial}) for site $site"
                                lib_found=1
                                break
                        fi
                done
                [[ $lib_found -eq 0 ]] && exit_code=7 && err_msg
        else
                exit_code=8
                err_msg
        fi
        exit_code=0
}

get_inventory() {

        if [[ ! -f "${inventory_file}" ]]; then
               ${exec_touch} "${inventory_file}" 2>/dev/null || exit_code=10
               [[ $exit_code -ne 0 ]] && err_msg
        fi

        $exec_itdt -f $libr inventory 1>${inventory_file} 2> >(write_log)
        [[ $? -ne 0 ]] && exit_code=11 && err_msg || write_log "INFO: inventory file created ${inventory_file}"
        exit_code=0
}

get_tape() {
        # Prepare list of dirty tapes
        dirty_list=$(${exec_cat} "${dirty_tapes}" 2>/dev/null | ${exec_grep} -v '#' | ${exec_awk} -F';' '{print $1}' | ${exec_sed} -e 's/$/|/g' | ${exec_xargs} | ${exec_tr} -d ' '| ${exec_sed} -e 's/|$//g')

        # Get free tapes in all slots
        # Examles of source inventory data:
        # Slot Address ................... 1070
        #  Slot State .................... Normal
        #  ASC/ASCQ ...................... 0000
        #  Media Present ................. Yes
        #  Robot Access Allowed .......... Yes
        #  Source Element Address Valid .. Yes
        #  Source Element Address ........ 1059
        #  Media Inverted ................ No
        #  Volume Tag .................... XXXXXXXX
        if [[ -n "${dirty_list}" ]]; then
                slots_arr=($(${exec_cat} ${inventory_file} 2>/dev/null | ${exec_grep} -E 'Slot Address' -A8 \
                        | ${exec_grep} -E 'Media Present .* Yes' -B3 -A5 | ${exec_grep} -E 'Slot Address|Volume Tag' \
                        | ${exec_grep} -Evi "${dirty_list}|${cln_tapes}" | ${exec_grep} 'Volume Tag' -B1 | ${exec_grep} -v '\-\-' \
                        | ${exec_grep} 'Slot Address' | ${exec_awk} '{print $NF}'))
                tapes_arr=($(${exec_cat} ${inventory_file} 2>/dev/null | ${exec_grep} -E 'Slot Address' -A8 \
                        | ${exec_grep} -E 'Media Present .* Yes' -B3 -A5 | ${exec_grep} -E 'Slot Address|Volume Tag' \
                        | ${exec_grep} -Evi "${dirty_list}|${cln_tapes}" | ${exec_grep} 'Volume Tag' -B1 | ${exec_grep} -v '\-\-' \
                        | ${exec_grep} 'Volume Tag' | ${exec_awk} '{print $NF}'))
        else
                slots_arr=($(${exec_cat} ${inventory_file} 2>/dev/null | ${exec_grep} -E 'Slot Address' -A8 \
                        | ${exec_grep} -E 'Media Present .* Yes' -B3 -A5 | ${exec_grep} -E 'Slot Address|Volume Tag' \
                        | ${exec_grep} -Evi "${cln_tapes}" | ${exec_grep} 'Volume Tag' -B1 | ${exec_grep} -v '\-\-' \
                        | ${exec_grep} 'Slot Address' | ${exec_awk} '{print $NF}'))
                tapes_arr=($(${exec_cat} ${inventory_file} 2>/dev/null | ${exec_grep} -E 'Slot Address' -A8 \
                        | ${exec_grep} -E 'Media Present .* Yes' -B3 -A5 | ${exec_grep} -E 'Slot Address|Volume Tag' \
                        | ${exec_grep} -Evi "${cln_tapes}" | ${exec_grep} 'Volume Tag' -B1 | ${exec_grep} -v '\-\-' \
                        | ${exec_grep} 'Volume Tag' | ${exec_awk} '{print $NF}'))
        fi

        len_slots=${#slots_arr[@]}
        len_tapes=${#tapes_arr[@]}

        # check that tapes inventory is not empty
        [[ ${len_slots} -eq 0 || ${len_tapes} -eq 0 ]] && exit_code=12 && err_msg

        # select random tape from free tapes
        rnd_idx=$((RANDOM % len_slots))
        slot_id=${slots_arr[${rnd_idx}]}
        tape_id=${tapes_arr[${rnd_idx}]}

        [[ -z "$slot_id" || -z "$tape_id" ]] && exit_code=12 && err_msg || write_log "INFO: selected tape $tape_id from slot $slot_id"
        exit_code=0
}

get_drive() {

        # Get free drives and select first free drives's slot number
        drv_list=$(${exec_cat} ${drv_cfg} | ${exec_grep} -i "$site" | ${exec_grep} -i "$access" | ${exec_awk} -F_ '{print $2}' | ${exec_sed} -e 's/$/,/g' | ${exec_xargs} | ${exec_tr} -d ' ' | ${exec_sed} -e 's/,$//g')
        if [[ -n "$drv_list" ]]; then
                drv_num=$(${exec_cat} ${inventory_file} 2>/dev/null | ${exec_grep} -E "Drive Address [${drv_list}]" -A3 \
                        | ${exec_grep} -E "Media Present .* No" -B3 | ${exec_grep} "Drive Address" | ${exec_awk} '{print $NF}' | head -1)
                [[ -z ${drv_num} ]] && exit_code=13 && err_msg
        else
                exit_code=14 && err_msg
        fi


        # Get tape device corresponding to selected slot
        ${exec_ls} -ls ${dev_tape}* >/dev/null 2>&1
        if [[ $? -eq 0 ]]; then
                drv_serial=$(${exec_cat} "$drv_cfg" 2>/dev/null | ${exec_grep} -i "$site" | ${exec_grep} "_${drv_num}_" | ${exec_awk} -F';' '{print $2}')
                [[ -z "$drv_serial" ]] && exit_code=15 && err_msg
                for i in $(${exec_ls} -ls ${dev_tape}* 2>/dev/null | ${exec_awk} '{print $NF}'); do
                        dev_serial=$(udevadm info --attribute-walk ${i} 2>/dev/null | ${exec_grep} -i 'serial' | ${exec_awk} -F'==' '{print $2}' | ${exec_tr} -d '"')
                        if [[ "$drv_serial" == "$dev_serial" ]]; then
                                # set selected tape drive device
                                drive_dev=$i
                                drive_name=$(${exec_cat} "$drv_cfg" 2>/dev/null | ${exec_grep} -i "$site" | ${exec_grep} "_${drv_num}_" | ${exec_awk} -F';' '{print $1}')
                                write_log "INFO: selected device: $drive_dev; drive: $drive_name (${drv_serial}) for site $site"
                                drv_found=1
                                break
                        fi
                done
                [[ $drv_found -eq 0 ]] && exit_code=16 && err_msg
        else
                exit_code=17
                err_msg
        fi
        exit_code=0
}

mount_tape() {
        $exec_itdt -f ${libr} move ${slot_id} ${drv_num}
        if [[ $? -eq 0 ]]; then
                write_log "INFO: mounted tape $tape_id from slot $slot_id to drive $drive_name (${drive_dev})"
        else
                exit_code=18
                err_msg
        fi
        exit_code=0
}

write_tape() {
        # start writing data to tape
	echo "INFO: starting transfer of ${is_datatype} ${data2bak} to tape $tape_id"
        write_log "INFO: starting transfer of ${is_datatype} ${data2bak} to tape $tape_id"
	${exec_tar} -b256 -cvf ${drive_dev} ${data2bak} > "${tape_content}_${tape_id}" 2>&1
        # check exit code
        if [[ $? -eq 0 ]]; then
                backup_ok="yes"
                DTB=$(${exec_date} +"%Y-%m-%d %T")
		echo "INFO: finished transfer of ${is_datatype} ${data2bak} to tape $tape_id"
                write_log "INFO: finished transfer of ${is_datatype} ${data2bak} to tape $tape_id"
        else
                DTB=$(${exec_date} +"%Y-%m-%d %T")
		echo "CRITICAL: $data2bak backup failed"
		write_log "CRITICAL: $data2bak backup failed"
                exit_code=20
                err_msg
        fi
        exit_code=0
}

update_dirtydb() {

        # update dirty tapes database
        if [[ ! -f ${dirty_tapes} ]]; then
                # create dirty tapes database file if it doesn't exist
                ${exec_touch} ${dirty_tapes} 2>/dev/null && echo "#TAPE_ID;TAPE_DESC" > ${dirty_tapes} || dirtydb_ok="no"
        else
                # remove the tapes which are no longer present in the library
                tape_to_remove=""
                for tape in $(${exec_cat} ${dirty_tapes} 2>/dev/null | ${exec_grep} -v 'TAPE_ID;TAPE_DESC' | ${exec_awk} -F';' '{print $1}'); do
                        [[ "${tape_to_remove}" == "" ]] && tape_to_remove=$([[ $(${exec_grep} ${tape} ${inventory_file}) ]] || echo ${tape}) \
                                || tape_to_remove=${tape_to_remove}$([[ $(${exec_grep} ${tape} ${inventory_file}) ]] || echo "|${tape}")
                done

                if [[ "$tape_to_remove" != "" ]]; then
                        ${exec_cat} ${dirty_tapes} 2>/dev/null | ${exec_grep} -Ev "$tape_to_remove" > ${tmp_dir}/tmpfile.txt \
                                && ${exec_mv} ${tmp_dir}/tmpfile.txt ${dirty_tapes} 2>/dev/null \
                                || dirtydb_ok="no"
                fi

        fi

        # add tape to dirty list
        Dbak=$(${exec_date} +"%Y-%m-%d")
        echo "${tape_id};Backup_${Dbak}${optional_description}" >> ${dirty_tapes} 2>/dev/null || dirtydb_ok="no"

        [[ "$dirtydb_ok" == "no" ]] && write_log "WARNING: can't update dirty tapes database - ${dirty_tapes}. This may cause tapes with data be rewritten!!!" && \
                return 0 || write_log "INFO: dirty tapes database was updated"

}

export_tape() {

        # refresh invnetory
        get_inventory

        # Prepare list of free export slots
        # Examles of source inventory data:
        # Import/Export Station Address 101
        #  Import/Export State ........... Normal
        #  ASC/ASCQ ...................... 0000
        #  Media Present ................. No
        #  Import Enabled ................ Yes
        #  Export Enabled ................ Yes
        #  Robot Access Allowed .......... Yes
        #  Source Element Address ........ N/A
        #  Location (Fra/Col/Row/Acc)..... 0/0/0/A (TS3500/4500 only)
        #  Media Inverted ................ No
        #  Volume Tag ....................

        free_io_slots=$(${exec_cat} ${inventory_file} 2>/dev/null | ${exec_grep} 'Export Station Address' -A3 \
                | ${exec_grep} -E 'Media Present .* No' -B3 \
                | ${exec_grep} 'Export Station Address' \
                | ${exec_awk} '{print $NF}')

        if [[ -n "${free_io_slots}" ]]; then
                export_slot=$(echo "${free_io_slots}" | head -1)
                exp_slot_ok="yes"
        else
                export_slot=${slot_id}
                exp_slot_ok="no"
        fi

        if [[ -n "${export_slot}" ]]; then
                #move tape to export slot
                $exec_itdt -f ${libr} move ${drv_num} ${export_slot}
                if [[ $? -eq 0 ]]; then
                        [[ "$exp_slot_ok" == "yes" ]] && msg_out="INFO: exported tape $tape_id to export slot ${export_slot} in library ${libr}"
                        [[ "$exp_slot_ok" == "no" ]] && msg_out="WARNING: all export slots are busy. The tape $tape_id was returned to slot ${export_slot} in library ${libr}"
                else
                        echo "ERROR: tape export failed. Check log file $log_file"
                        [[ "$exp_slot_ok" == "yes" ]] && err_msg_21="itdt failed to export tape $tape_id to export slot ${export_slot}"
                        [[ "$exp_slot_ok" == "no" ]] && err_msg_21="itdt failed to export tape $tape_id to library slot ${export_slot}"
                        export_slot="Drive ${drv_num}"
                        exit_code=21
                fi
        else
                #write error that export slot was not determined
                export_slot="Drive ${drv_num}"
                echo "Error: tape export failed. Check log file $log_file"
                err_msg_22="failed to assign export slot. Probably a scripting code error."
                exit_code=22
        fi

        [[ -n "${msg_out}" ]] && echo "$msg_out" && write_log "$msg_out"
        [[ ${exit_code} -ne 0 ]] && err_msg

}

write_journal() {
        args="$@"

        # create journal file if it doesn't exist
        if [[ ! -f ${backups_journal} ]]; then
                ${exec_touch} ${backups_journal} 2>/dev/null && echo "#DATE/TIME;STATUS;SITE;TAPE_ID;TAPE_LOCATION;DATASOURCE;DESCRIPTION" > ${backups_journal} || journal_ok="no"
        fi

        # add record to journal file
        if [[ "$backup_ok" == "yes" ]]; then
                echo "${DTB};SUCCESS;${site};${tape_id};${export_slot};Offsite backup of ${data2bak};${optional_description}" \
                        >> ${backups_journal} 2>/dev/null || journal_ok="no"
        fi

        [[ "$journal_ok" == "no" ]] && write_log "WARNING: can't update backups journal - ${backups_journal}. Check path and permissions." && \
                return 0 || write_log "INFO: backup record added to journal file ${backups_journal}"
}

# MAIN

[[ ${exit_code} -ne 0 ]] && err_msg

check_datasource

get_lib $site

get_inventory

get_tape

get_drive

mount_tape

write_tape

update_dirtydb

export_tape

write_journal

[[ "$backup_ok" == "yes" ]] && echo "INFO: $data2bak backup finished successfuly" && write_log "INFO: $data2bak backup finished successfuly"
[[ "$backup_ok" == "no" ]] && echo "CRITICAL: $data2bak backup failed" && write_log "CRITICAL: $data2bak backup failed"

