#!/bin/bash

logfile=/tmp/perf-test-script-$(date +"%Y%m%dT%H%M%S%z").log
confdlogfile=/tmp/perf-test-confd-$(date +"%Y%m%dT%H%M%S%z").log

CURLOPT=-f
location="RibbonLab"
#appType="sbc"
#sbcType="isbc"

function printUsage()
{
    echo "usage: perf-test.sh -u user -p password -c count [ -s cpu_steal_threshold ] [ -l logfile ] [ -d ]"
}

function printSeparator()
{
    echo "---------------------------------------------------------------------------------------------------"
}

function parseCmdlineArgs()
{

    stealThreshold=3
    tgTestCount=0
    options=$(getopt -o "du:p:c:s:l:" -l "tgUpdateFile:,tgUpdateCount:" -- "$@")

    if [ $? -ne 0 ]; then  
        printUsage
        exit 1
    fi

    eval set -- "$options"

    while [ ! -z "$1" ]; do
        case "$1" in
            -u|--user)
                user=$2
                shift
                ;;
            -p|--password)
                password=$2
                shift
                ;;
            -c|--count)
                tgTestCount=$2
                shift
                ;;
            -s|--steal)
                stealThreshold=$2
                shift;
                ;;
            --tgUpdateFile)
                tgUpdateFile=$2
                shift;
                ;;
            --tgUpdateCount)
                tgUpdateCount=$2
                shift;
                ;;
            -l|--log)
                logfile=$2
                shift;
                ;;
            -d|--debug)
                debug=1
                set -x
                CURLOPT=${CURLOPT}i
                ;;
            --)
                shift
                break
                ;;
        esac
        shift
    done

    if [[ -z $password ]]; then
        read -p "password Enter CLI password for user $user: " password
    fi
}


function isSuccess
{
    if [[ $? -ne 0 ]]; then
        echo "command failed. $@"
        return 1;
    fi

    return 0
}

function myexpr
{
    awk 'BEGIN{print '"$@"'}';
}

export -f myexpr

function fetch_sbx_start_time()
{
    SD="/var/log/sonus/sbx/";
    ASP_FMT='%-76s %-14s %-5s'
    ASP_SAVED_LOGS="$SD/asp_saved_logs/normal/log*/"
    ASP_CUR_LOG="$SD/openclovis/"

    printSeparator
    echo "                           SBX START TIME                                       "
    printSeparator

    printf "$ASP_FMT\n" "Dir" "Role" "Time"

    for dir in `ls -ld $ASP_SAVED_LOGS 2>/dev/null| awk '{print $9}'` `ls -ld $ASP_CUR_LOG 2>/dev/null| awk '{print $9}'`; do

            unset start
            unset stop
        unset time

        #grep -s -m1 Initializing $dir/app.latest 
        #grep -s -m 1 'EmaProc.*process.* completed:' $dir/app.latest 

        start=$(grep -s -m1 Initializing $dir/app.latest | cut -c 5-29)
        stop=$(grep -s -m 1 'EmaProc.*process.* completed:' $dir/app.latest | cut -c 5-29)
        grep -sq -m1 AMF_EVENT_ACTIVATE $dir/app.latest && role="Active"
        grep -sq -m1 AMF_EVENT_STANDBY  $dir/app.latest && role="Standby"

        if [[ -n $start && -n $stop ]]; then
            start=$(  date --date="$start" '+%g-%m-%d %H:%M:%S' 2>/dev/null)
            stop=$(   date --date="$stop"  '+%g-%m-%d %H:%M:%S' 2>/dev/null)
            start=$(  date --date="$start" +%s)
            stop=$(   date --date="$stop"  +%s)
            time=$((stop - start))
            printf "$ASP_FMT\n" "$dir" "$role" "${time}s"
        fi
    done
}

function updateTgWithCli()
{
    local file=/tmp/cli-update.tmp
    > $file

    echo configure >> $file
    for (( i=0; i<$tgTestCount; i++)); do
            cat "$tgUpdateFile" | sed -nE "s/.*sipTrunkGroup\s+\S+/set addressContext default zone defaultSigZone sipTrunkGroup TEST_TG_$i /p"  >> $file
            
            if [[ $(( (i+1) % tgUpdateCount )) -eq 0 ]]; then
                echo commit >> $file
            fi
		set +x
    done;
    echo commit >> $file

    cp $file /home/sftproot/Administrator/admin/ 
    chmod 777 /home/sftproot/Administrator/admin/$(basename $file)

    cd  /home/sftproot/Administrator/admin/
    (echo source $(basename $file)) | /opt/sonus/sbx/tailf/bin/confd_cli -u admin 
}

function createTgWithCli()
{
    local file=/tmp/cli-create.tmp
    > $file

    echo configure >> $file
    for (( i=0; i<$tgTestCount; i++)); do
            echo "set addressContext default zone defaultSigZone sipTrunkGroup TEST_TG_$i media mediaIpInterfaceGroupName TEST_LIG_1"  >> $file
            
            if [[ $(( (i+1) % 2 )) -eq 0 ]]; then
                echo commit >> $file
            fi
		set +x
    done;
    echo commit >> $file

    cp $file /home/sftproot/Administrator/admin/ 
    chmod 777 /home/sftproot/Administrator/admin/$(basename $file)

    cd  /home/sftproot/Administrator/admin/
    (echo source $(basename $file)) | /opt/sonus/sbx/tailf/bin/confd_cli -u admin 
}

function disableTgWithCli()
{
    out=$( (echo show configuration addressContext default zone defaultSigZone sipTrunkGroup TEST_TG_0 ) | /opt/sonus/sbx/tailf/bin/confd_cli -u admin)

    UD=0
    echo "$out" | grep "state.*enabled" && UD=1
    echo "$out" | grep "mode.*inService" && UD=1

    if [[ $UD -eq 1 ]]; then
        local file=/tmp/cli-disable.tmp
        > $file

        echo configure >> $file
        for (( i=0; i<$tgTestCount; i++)); do
                echo "set addressContext default zone defaultSigZone sipTrunkGroup TEST_TG_$i state disabled mode outOfService"  >> $file
                
                if [[ $(( (i+1) % 5 )) -eq 0 ]]; then
                    echo commit >> $file
                fi
            set +x
        done;
        echo commit >> $file

        cp $file /home/sftproot/Administrator/admin/ 
        chmod 777 /home/sftproot/Administrator/admin/$(basename $file)

        cd  /home/sftproot/Administrator/admin/
        (echo source $(basename $file)) | /opt/sonus/sbx/tailf/bin/confd_cli -u admin 
    fi
}

function deleteTgWithCli()
{
    local file=/tmp/cli-delete.tmp
    > $file

    echo configure >> $file
    for (( i=0; i<$tgTestCount; i++)); do
            echo "delete addressContext default zone defaultSigZone sipTrunkGroup TEST_TG_$i"  >> $file
            
            if [[ $(( (i+1) % 3 )) -eq 0 ]]; then
                echo commit >> $file
            fi
		set +x
    done;
    echo commit >> $file

    cp $file /home/sftproot/Administrator/admin/ 
    chmod 777 /home/sftproot/Administrator/admin/$(basename $file)

    cd  /home/sftproot/Administrator/admin/
    (echo source $(basename $file)) | /opt/sonus/sbx/tailf/bin/confd_cli -u admin 
}

function sbx_config_perf_test()
{
    if [[ $tgTestCount -eq 0 ]]; then
        return;
    fi

    OUT=$(curl -kisu "$user:$password" "https://localhost/api")

    if [[ $? -ne 0 ]];  then
        echo "$OUT"
        echo "error: unable to connect to REST API interface."
        exit 1;
    fi

    echo "$OUT" | grep -q "HTTP/1.1 200 OK" 

    if [[ $? -ne 0 ]]; then
        echo "$OUT"
        echo "error: curl failed. Check credentials and max sesssions opened."
        exit 1;
    fi

    tail -F -n 3 /opt/sonus/sbx/tailf/var/confd/log/devel.log 2>/dev/null > $confdlogfile &
    tailpid=$!

    OUT=$(curl $CURLOPT -ksu "$user:$password" -XPUT  -H 'Content-Type: application/vnd.yang.data+xml'  https://localhost/api/config/addressContext/default/ipInterfaceGroup/TEST_LIG_1 -d "
    <ipInterfaceGroup>
         <name>TEST_LIG_1</name>
    </ipInterfaceGroup>
    ")

    start=$(date +%s)

    if [[ -z $tgUpdateFile ]] || [[ -z $tgUpdateCount ]] ; then
        for (( i=0; i<$tgTestCount; i++)); do
            OUT=$(curl $CURLOPT -ksu "$user:$password" -XPOST  -H 'Content-Type: application/vnd.yang.data+xml'  https://localhost/api/config/addressContext/default/zone/defaultSigZone -d "
            <sipTrunkGroup>
                 <name>TEST_TG_$i</name>
                     <state>disabled</state>
                 <media>
                 <mediaIpInterfaceGroupName>TEST_LIG_1</mediaIpInterfaceGroupName>
                 </media>
            </sipTrunkGroup>
            ")

            isSuccess "$OUT"
        done;
    else
        createTgWithCli
    fi

    stop=$(date +%s)
    TG_CREATE_TIME=$((stop-start))

    #------------------------------------------------------------------------------------------------------------------------#

    start=$(date +%s)

    if [[ -z $tgUpdateFile ]] || [[ -z $tgUpdateCount ]] ; then

	    for (( i=0; i<$tgTestCount; i++)); do
		OUT=$(curl $CURLOPT -ksu "$user:$password" -XPATCH  -H 'Content-Type: application/vnd.yang.data+xml'  https://localhost/api/config/addressContext/default/zone/defaultSigZone/sipTrunkGroup/TEST_TG_$i  -d "
		<sipTrunkGroup>
		     <name>TEST_TG_$i</name>
		     <sipResponseCodeStats>enabled</sipResponseCodeStats>
		</sipTrunkGroup>
		")

		isSuccess "$OUT"
	    done;
    else
        updateTgWithCli	
    fi

    stop=$(date +%s)
    TG_UPDATE_TIME=$((stop-start))

    #------------------------------------------------------------------------------------------------------------------------#
    if [[ -z $tgUpdateFile ]] || [[ -z $tgUpdateCount ]] ; then
        true;
    else
        # Disable support only on CLI now
        disableTgWithCli
    fi
    #------------------------------------------------------------------------------------------------------------------------#

    start=$(date +%s)

    if [[ -z $tgUpdateFile ]] || [[ -z $tgUpdateCount ]] ; then
        for (( i=0; i<$tgTestCount; i++)); do
            OUT=$(curl $CURLOPT -ksu "$user:$password" -XDELETE  https://localhost/api/config/addressContext/default/zone/defaultSigZone/sipTrunkGroup/TEST_TG_$i)
            isSuccess "$OUT"
        done;
    else
        deleteTgWithCli
    fi

    stop=$(date +%s)
    TG_DEL_TIME=$((stop-start))

    printSeparator
    echo "         Configuration Performance Test with REST API                           "
    printSeparator
    printf "%-15s %-15s %-15s %-15s %-15s\n" TYPE  COUNT    CREATE_TIME     UPDATE_TIME     DELETE_TIME
    printf "%-15s %-15s %-15s %-15s %-15s\n" TG   $tgTestCount $TG_CREATE_TIME $TG_UPDATE_TIME $TG_DEL_TIME
    printf "%-15s %-15s %-15s %-15s %-15s\n" TG   1         $(myexpr "$TG_CREATE_TIME/$tgTestCount") $(myexpr "$TG_UPDATE_TIME/$tgTestCount") $(myexpr "$TG_DEL_TIME/$tgTestCount")

    avgTgCreateTime=$(myexpr "$TG_CREATE_TIME/$tgTestCount")
    avgTgModifyTime=$(myexpr "$TG_UPDATE_TIME/$tgTestCount")
    avgTgDeleteTime=$(myexpr "$TG_DEL_TIME/$tgTestCount") 

    kill -9 "$tailpid" >& /dev/null
    wait "$tailpid" >& /dev/null

}

function steal_check()
{
    local header=0

    for i in $(find /var/log/sonus/sbxPerf/ -regextype sed -regex "/var/log/sonus/sbxPerf/mpstat.log\(\|.[0-9]*\)" 2>/dev/null);
    do
        OUT=$(awk '{print $1" "$2" "$10}' $i | grep -v 'steal\|Linux\|^[ ]*$' | awk  '$3>'"$stealThreshold");
        if [[ -n $OUT ]]; then
            if [[ $header -eq 0 ]]; then
                printSeparator
                echo "         Instances where CPU STEAL was greater than $stealThreshold                                "
                header=1
            fi
            echo "---- $i " $(grep '^Linux' $i | awk '{print $4}' | sort -u |  paste -s -d " ");
            echo "$OUT";
        fi;
    done;

    if [[ $header -eq 0 ]]; then
        printSeparator
        echo "         Steal was never greater than $stealThreshold                                              "
    fi
}

function disk_perf_test()
{
    printSeparator
    for i in /dev/[vs]da*; do  
        hdparm -Tt $i 2>/dev/null | grep -v '^$'; 
    done
}

function fetch_system_info()
{
	OUT=$(/opt/sonus/sbx/scripts/hwinfo.sh -l)
	memory=$(echo "$OUT" | grep "System Memory" | awk '{print $4}')
	cpuCount=$(echo "$OUT" | sed -nE 's/Number of Virtual CPUs : (.*)/\1/p')
	sbcType=$(/opt/sonus/sbx/scripts/swinfo.sh -l | sed -nE 's/SBC Type:\s*(.*)/\1/p')
	appType=$(cat /etc/application 2>/dev/null)
	[ -n $appType ] || appType=sbc

	printSeparator
	printf "%-15s : %-15s\n" "appType" "$appType"
	printf "%-15s : %-15s\n" "sbcType" "$sbcType"
	printf "%-15s : %-15s\n" "cpu"     "$cpuCount"
	printf "%-15s : %-15s\n" "memory"  "$memory"

}

function main()
{
    parseCmdlineArgs "$@"

    sbx_config_perf_test                        

    steal_check                                 

    #disk_perf_test                              

    fetch_sbx_start_time                        

    printSeparator                              

    fetch_system_info                           

    echo "Test Time       : $SECONDS seconds"  
    echo "Log Files       : $logfile"
    echo "                : $confdlogfile"

}

main "$@" | tee $logfile
