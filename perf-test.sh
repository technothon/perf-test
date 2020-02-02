#!/bin/bash

CURLOPT=-f
location="RibbonLab"
#appType="sbc"
#sbcType="isbc"
jsonFile="/tmp/data.json"

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
    logfile=/tmp/perf-test.log

    stealThreshold=3
    tgTestCount=0
    options=$(getopt -o "du:p:c:s:l:" -- "$@")

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

    echo "user=$user, password=$password, count=$tgTestCount, steal_threshold=$stealThreshold"

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


function sbx_config_perf_test()
{
    if [[ $tgTestCount -eq 0 ]]; then
        return;
    fi

    OUT=$(curl -kifsu "$user:$password" "https://localhost/api")

    if [[ $? -ne 0 ]]; then
        echo "Unable to connect to REST API interface."
        echo "$OUT"
        exit 1;
    fi

    OUT=$(curl $CURLOPT -ksu "$user:$password" -XPUT  -H 'Content-Type: application/vnd.yang.data+xml'  https://localhost/api/config/addressContext/default/ipInterfaceGroup/TEST_LIG_1 -d "
    <ipInterfaceGroup>
         <name>TEST_LIG_1</name>
    </ipInterfaceGroup>
    ")


    start=$(date +%s)

    for (( i=0; i<$tgTestCount; i++)); do
        OUT=$(curl $CURLOPT -ksu "$user:$password" -XPOST  -H 'Content-Type: application/vnd.yang.data+xml'  https://localhost/api/config/addressContext/default/zone/defaultSigZone -d "
        <sipTrunkGroup>
             <name>TEST_TG_$i</name>
                 <state>enabled</state>
             <media>
             <mediaIpInterfaceGroupName>TEST_LIG_1</mediaIpInterfaceGroupName>
             </media>
        </sipTrunkGroup>
        ")

        isSuccess "$OUT"
    done;

    stop=$(date +%s)
    TG_CREATE_TIME=$((stop-start))

    start=$(date +%s)

    for (( i=0; i<$tgTestCount; i++)); do
        OUT=$(curl $CURLOPT -ksu "$user:$password" -XPATCH  -H 'Content-Type: application/vnd.yang.data+xml'  https://localhost/api/config/addressContext/default/zone/defaultSigZone/sipTrunkGroup/TEST_TG_$i  -d "
        <sipTrunkGroup>
             <name>TEST_TG_$i</name>
                 <state>disabled</state>
             <sipResponseCodeStats>enabled</sipResponseCodeStats>
        </sipTrunkGroup>
        ")

        isSuccess "$OUT"
    done;

    stop=$(date +%s)
    TG_UPDATE_TIME=$((stop-start))

    start=$(date +%s)

    for (( i=0; i<$tgTestCount; i++)); do
        OUT=$(curl $CURLOPT -ksu "$user:$password" -XDELETE  https://localhost/api/config/addressContext/default/zone/defaultSigZone/sipTrunkGroup/TEST_TG_$i)
        isSuccess "$OUT"
    done;

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

cat > $jsonFile << EOF
	"cfgPerfStats" : {
		"tgTestCount"     : "$tgTestCount",
		"avgTgCreateTime" : "$avgTgCreateTime",
		"avgTgModifyTime" : "$avgTgModifyTime",
		"avgTgDeleteTime" : "$avgTgDeleteTime"
	}
}
EOF

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

    sbx_config_perf_test                        |& tee    $logfile

    steal_check                                 |& tee -a $logfile

    disk_perf_test                              |& tee -a $logfile

    fetch_sbx_start_time                        |& tee -a $logfile

    printSeparator                              |& tee -a $logfile

    fetch_system_info                           |& tee -a $logfile

    echo "Time taken to test $SECONDS seconds"  |& tee -a $logfile

}

main "$@"
