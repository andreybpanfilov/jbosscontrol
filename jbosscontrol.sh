#!/bin/sh


# Please ensure that console output enabled, see conf/jboss-log4j.xml
#   <!-- ============================== -->
#   <!-- Append messages to the console -->
#   <!-- ============================== -->
#   <appender name="CONSOLE" class="org.apache.log4j.ConsoleAppender">
#      <errorHandler class="org.jboss.logging.util.OnlyOnceErrorHandler"/>
#      <param name="Target" value="System.out"/>
#      <param name="Threshold" value="INFO"/>
#
#      <layout class="org.apache.log4j.PatternLayout">
#         <param name="ConversionPattern" value="%d{ABSOLUTE} %-5p [%c{1}] %m%n"/>
#      </layout>
#   </appender>
#
#   <!-- ====================== -->
#   <!-- More Appender examples -->
#   <!-- ====================== -->
#
#   <!-- Buffer events and log them asynchronously -->
#   <appender name="ASYNC" class="org.apache.log4j.AsyncAppender">
#     <errorHandler class="org.jboss.logging.util.OnlyOnceErrorHandler"/>
#     <!--
#     <appender-ref ref="FILE"/>
#     -->
#     <appender-ref ref="CONSOLE"/>
#     <!--
#     <appender-ref ref="SMTP"/>
#     -->
#   </appender>


###############################################################################
# Node manager shell script version.                                          #
###############################################################################

###############################################################################
# helper functions                                                            #
###############################################################################

###############################################################################
# Reads a line from the specified file and returns it in REPLY.               #
# Error message supressed if file not found.                                  #
###############################################################################
read_file() {
  if [ -f "$1" ]; then
    read REPLY 2>$NullDevice <"$1"
  else
    return 1
  fi
}

###############################################################################
# Writes a line to the specified file. The line will first be written         #
# to a temporary file which is then used to atomically overwrite the          #
# destination file. This prevents a simultaneous read from getting            #
# partial data.                                                               #
###############################################################################
write_file() {
  file="$1"; shift
  echo $* >>"$file.tmp"
  mv -f -- "$file.tmp" "$file"
}

###############################################################################
# Updates the state file with new server state information.                   #
###############################################################################
write_state() {
  write_file "$StateFile" "$1"
}

###############################################################################
# Prints informational message to server output log.                          #
###############################################################################
print_info() {
  echo "<`date`> <Info> <NodeManager> <"$@">"
}

###############################################################################
# Prints error message to server output log.                                  #
###############################################################################
print_err() {
  echo "<`date`> <Error> <NodeManager> <"$@">"
}

###############################################################################
# Reads system property from $JAVA_OPTS                                       #
###############################################################################
read_property() {
  PropValue=$(echo "$JAVA_OPTS" | sed -e 's/.*-D'"$1"'=\(\"\(\(\([^\"]\|\(\\\"\)\)*\)\)\"\|\(\(\(\\ \)\|[^ ]\)*\)\).*/\1/;s/^\"//;s/\"$//')
  if [ "x$PropValue" = "x$JAVA_OPTS" ]; then
    PropValue=""
  fi
}

###############################################################################
# Removes system property from $JAVA_OPTS                                     #
###############################################################################
remove_property() {
  JAVA_OPTS=$(echo "$JAVA_OPTS" | sed -e 's/-D'"$1"'=\(\"\(\(\([^\"]\|\(\\\"\)\)*\)\)\"\|\(\(\(\\ \)\|[^ ]\)*\)\)//')
}

###############################################################################
# reads java pid to $svrv_pid variable
###############################################################################
read_java_pid() {
  # Check for pid file
  read_file "$PidFile"

  if [ "x$?" = "x0" ]; then
    srvr_pid=$REPLY
  fi

  # Make sure server is started
  if ! monitor_is_running; then
    return 1
  fi

  if ! java_is_running; then
    return 1
  fi

  return 0
}

###############################################################################
# Force kill jboss pid                                                        #
###############################################################################
force_kill() {
  read_java_pid
  if [ "x$?" = "x0" -a "x$srvr_pid" != "x" ]; then
    kill -9 $srvr_pid
    return $?
  else
    print_err "Jboss is not currently running" >&2
    return 1
  fi
}

###############################################################################
# Makes thread dump of the running java process.                              #
###############################################################################
make_thread_dump() {
  read_java_pid
  if [ "x$?" = "x0" -a "x$srvr_pid" != "x" ]; then
    kill -3 $srvr_pid
    return $?
  else
    print_err "Jboss is not currently running" >&2
    return 1
  fi
}

###############################################################################
# Makes thread dump of the running java process and executes less             #
###############################################################################
list_thread_dump() {
  make_thread_dump
  if [ "x$?" = "x0" ]; then
    sleep 1
    less +"?Full thread dump Java HotSpot" -- "$OutFile"
  else
    print_err "Jboss is not currently running" >&2
    return 1
  fi
}

###############################################################################
# Returns true if the process with the specified pid is still alive.          #
###############################################################################
is_alive() {
  if [ -d /proc/self ]; then
    [ -r "/proc/$1" -a "x" != "x$1" ]
  else
    ps -p $1 2>$NullDevice | grep -q $1
  fi
}

###############################################################################
# Returns true if the server state file indicates                             #
# that the server has started.                                                #
###############################################################################
server_is_started() {
  if read_file "$StateFile"; then
    case $REPLY in
      *:Y:*) return 0 ;;
    esac
  fi
  return 1
}

###############################################################################
# Returns true if the server state file indicates                             #
# that the server has not yet started.                                        #
###############################################################################
server_not_yet_started() {
  if server_is_started; then
    return 1;
  else
    return 0;
  fi
}

###############################################################################
# Returns true if the monitor is running otherwise false. Also will remove    #
# the monitor lock file if it is no longer valid.                             #
###############################################################################
monitor_is_running() {
  if read_file "$LockFile" && is_alive $REPLY; then
    /sbin/fuser "$LockFile" > $NullDevice 2>&1
    if [ "x$?" = "x0" ]; then
      return 0
    fi
  fi
  rm -f -- "$LockFile"
  return 1
}

###############################################################################
# Returns true if the java is running otherwise false. Also will remove       #
# the pid file if it is no longer valid.                                      #
###############################################################################
java_is_running() {
  if read_file "$PidFile" && is_alive $REPLY; then
    /sbin/fuser "$PidFile" > $NullDevice 2>&1
    if [ "x$?" = "x0" ]; then
      return 0
    fi
  fi
  rm -f -- "$PidFile"
  return 1
}

###############################################################################
# Get the current time as an equivalent time_t.  Note that this may not be    #
# always right, but should be good enough for our purposes of monitoring      #
# intervals.                                                                  #
###############################################################################
time_as_timet() {
    if [ "x$BaseYear" = "x0" ]; then
        BaseYear=1970
    fi
    cur_timet=`date -u +"%Y %j %H %M %S" | awk '{
        base_year = 1970
        year=$1; day=$2; hour=$3; min=$4; sec=$5;
        yearsecs=int((year  - base_year)* 365.25 ) * 86400
        daysecs=day * 86400
        hrsecs=hour*3600
        minsecs=min*60
        total=yearsecs + daysecs + hrsecs + minsecs + sec
        printf "%08d", total
        }'`
}

###############################################################################
# Update the base start time if it is 0.  Every time a server stops,          #
# if the time since last base time is > restart interval, it is reset         #
# to 0.  Next restart of the server will set the last base start time         #
# to the new time                                                             #
###############################################################################
update_base_time() {
  time_as_timet
  if [ "x$LastBaseStartTime" = "x0" ]; then
    LastBaseStartTime=$cur_timet
  fi
}

###############################################################################
# Computes the seconds elapsed between last start time and current time       #
###############################################################################
compute_diff_time() {
    #get current time as time_t
    time_as_timet
    diff_time=`expr $cur_timet - $LastBaseStartTime`
}

###############################################################################
# Kills process tree                                                          #
###############################################################################
killtree() {
  local pid=$1
  local sig=${2-TERM}
  print_info "Stopping pid $pid"
  kill -stop $pid
  if [ "x$?" = "x0" ]; then
    for child in `ps -o pid --no-headers --ppid $pid`; do
      killtree $child $sig
    done
    print_info "Sending $sig signal to $pid"
    kill -$sig $pid
    kill -CONT $pid
  fi
}

###############################################################################
# Rotate the specified log file. Rotated log files are named                  #
# <server-name>.outXXXXX where XXXXX is the current log count and the         #
# highest is the most recent. The log count starts at 00001 then cycles       #
# again if it reaches 99999.                                                  #
###############################################################################
save_log() {
  fileLen=`echo "${OutFile}" | wc -c`
  fileLen=`expr ${fileLen} + 1`
  lastLog=`ls -r1 -- "$OutFile"????? "$OutFile" 2>$NullDevice | head -1`
  logCount=`ls -r1 -- "$OutFile"????? "$OutFile" 2>$NullDevice | head -1 | cut -c $fileLen-`
  if [ "x$logCount" = "x" ]; then
    logCount=0
  fi
  if [ "x$logCount" = "x99999" ]; then
    logCount=0
  fi
  logCount=`expr ${logCount} + 1`
  zeroPads=""
  case $logCount in
    [0-9]) zeroPads="0000" ;;
    [0-9][0-9]) zeroPads="000" ;;
    [0-9][0-9][0-9]) zeroPads="00" ;;
    [0-9][0-9][0-9][0-9]) zeroPads="0" ;;
  esac
  rotatedLog="$OutFile"$zeroPads$logCount
  mv -f -- "$OutFile" "$rotatedLog"
  /sbin/fuser -k -HUP "$rotatedLog" >$NullDevice 2>&1
}

###############################################################################
# Rotate the specified log file in size based manner                          #
###############################################################################
start_log_rotate() {
  while true; do
    trap "" 1
    sleep 60
    if [ -f "$OutFile" ]; then
      size=`stat -c '%s' -- "$OutFile"`
      if [ $size -ge $LogRotateSize ]; then
        save_log
      fi
    fi
  done
}

###############################################################################
# Detect deadlocks
###############################################################################
start_deadlock_detection() {
  while true; do
    sleep $DeadlockDetectionInterval
    check_deadlock
    if [ "x$?" = "x0" ]; then
      print_info "Found deadlock"
      make_thread_dump
      force_kill
    fi
  done
}

###############################################################################
# Checks whether java process has a deadlock                                  #
###############################################################################
check_deadlock() {
  if [ ! -x "$JAVA_HOME/bin/jstack" ]; then
    return 1
  fi

  read_java_pid
  if [ "x$?" = "x0" -a "x$srvr_pid" != "x" ]; then
    $JAVA_HOME/bin/jstack $srvr_pid | grep 'Found .* Java-level deadlock' > $NullDevice 2>&1
    return $?
  fi

  return 1
}


###############################################################################
# Make sure server directory exists and is valid.                             #
###############################################################################
check_dirs() {
  if [ ! -d "$JBOSS_HOME" ]; then
    print_err "Directory '$JBOSS_HOME' not found.  Make sure jboss directory exists and is accessible" >&2
    exit 1
  fi

  if [ ! -d "$ServerDir" ]; then
    print_err "Directory '$ServerDir' not found.  Make sure jboss server directory exists and is accessible" >&2
    exit 1
  fi

  mkdir -p -- "$ServerDir/log"
  mkdir -p -- "$ServerDir/nodemanager"
}

###############################################################################
# Process node manager START command. Starts server with current startup      #
# properties and enters the monitor loop which will automatically restart     #
# the server when it fails.                                                   #
###############################################################################
do_start() {
  # Make sure server is not already started
  if monitor_is_running; then
    print_err "Jboss has already been started" >&2
    return 1
  fi
  # If monitor is not running, but if we can determine that the Jboss
  # process is running, then say that server is already running.
  if java_is_running; then
    print_err "Jboss has already been started" >&2
    return 1
  fi
  # Save previous server output log
  if [ -f "$OutFile" ]; then
    save_log
  fi
  # Remove previous state file
  rm -f -- "$StateFile"
  # Change to server root directory
  cd -- "$ServerDir"
  # Now start the server and monitor loop
  start_and_monitor_server &
  # Wait for server to start up

  count=0
  while is_alive $! && server_not_yet_started; do
    sleep 1
    count=`expr ${count} + 1`
    if [ "x$StartTimeout" != "x0" ]; then
      if [ $count -gt $StartTimeout ]; then
        print_err "Jboss failed to start within $StartTimeout seconds, exiting" >&2
        do_kill
        return 1
      fi
    fi
  done
  if server_not_yet_started; then
    print_err "Jboss failed to start (see server output log for details)" >&2
    return 1
  fi
  return 0
}

start_and_monitor_server() {

  # Create server lock file
  pid=`exec sh -c 'ps -o ppid -p $$|sed '1d''`
  write_file "$LockFile" $pid
  exec 3>>"$LockFile"

  trap "rm -f -- \"$LockFile\"" 0
  trap "exec >>\"$OutFile\" 2>&1" 1
  # Disconnect input and redirect stdout/stderr to server output log
  exec 0<$NullDevice
  exec >>"$OutFile" 2>&1
  # Start server and monitor loop
  count=0

  setup_jboss_cmdline

  if [ "x$?" != "x0" ]; then
    print_err "Unable to setup cmd line"
    write_state FAILED_NOT_RESTARTABLE:N:Y
    return 1
  fi

  while true; do
    count=`expr ${count} + 1`
    update_base_time

    if [ "x$LogRotateSize" != "x0" ]; then
      start_log_rotate &
      print_info "Starting log rotating, pid $!"
    fi

    if [ "x$DeadlockDetectionInterval" != "x0" ]; then
      start_deadlock_detection &
      print_info "Starting deadlock detection, pid $!"
    fi

    start_server_script

    for job_pid in `jobs -p`; do
      print_info "Killing pid $job_pid"
      killtree $job_pid
    done

    read_file "$StateFile"
    case $REPLY in
      *:N:*)
        print_err "Server startup failed (will not be restarted)"
        write_state FAILED_NOT_RESTARTABLE:N:Y
        return 1
      ;;
      SHUTTING_DOWN:*:N | FORCE_SHUTTING_DOWN:*:N)
        print_info "Server was shut down normally"
        write_state SHUTDOWN:Y:N
        return 0
      ;;
    esac
    compute_diff_time
    if [ $diff_time -gt $RestartInterval ]; then
      #Reset count
      count=0
      LastBaseStartTime=0
    fi
    if [ "x$AutoRestart" != "xtrue" ]; then
      print_err "Server failed but is not restartable because autorestart is disabled."
      write_state FAILED_NOT_RESTARTABLE:Y:N
      return 1
    elif [ $count -gt $RestartMax ]; then
      print_err "Server failed but is not restartable because the maximum number of restart attempts has been exceeded"
      write_state FAILED_NOT_RESTARTABLE:Y:N
      return 1
    fi
    print_info "Server failed so attempting to restart"
      # Optionally sleep for RestartDelaySeconds seconds before restarting
    if [ $RestartDelaySeconds -gt 0 ]; then
      write_state FAILED:Y:Y
      sleep $RestartDelaySeconds
    fi
  done
}

###############################################################################
# Starts the Jboss server                                                     #
###############################################################################
start_server_script() {
  print_info "Starting Jboss with command line: $CommandName $CommandArgs"
  write_state STARTING:N:N
  (

     pid=`exec sh -c 'ps -o ppid -p $$|sed '1d''`

     write_file "$PidFile" $pid
     exec 3>>"$PidFile"

     exec $CommandName $CommandArgs 2>&1) | (
     trap "exec >>\"$OutFile\" 2>&1" 1
     IFS=""; while read line; do
       case $line in
         *java.net.BindException:*)
           read_file "$StateFile"
           case $REPLY in
             STARTING:N:N)
               print_err "Got fatal error, exiting"
               write_state FAILED_NOT_RESTARTABLE:N:Y
               force_kill
             ;;
           esac
	 ;;
#JBoss AS 7.1.1
         *JBAS015874:\ JBoss\ AS\ 7.1.1.Final\ \"Brontes\"\ started\ in*)
           write_state RUNNING:Y:N
         ;;
         *JBAS015950:\ JBoss\ AS\ 7.1.1.Final\ \"Brontes\"\ stopped\ in*)
           write_state SHUTTING_DOWN:Y:N
         ;;
#WildFly Full 9.0.1.Final
         *WFLYSRV0025:\ WildFly\ Full\ 9.0.1.Final\ \(WildFly\ Core\ 1.0.1.Final\)\ started\ in*)
           write_state RUNNING:Y:N
         ;;
         *WFLYSRV0050:\ WildFly\ Full\ 9.0.1.Final\ \(WildFly\ Core\ 1.0.1.Final\)\ stopped\ in*)
           write_state SHUTTING_DOWN:Y:N
         ;;
       esac
       echo $line;
    done
  )

  print_info "Jboss exited"
  return 0
}

setup_jboss_cmdline() {

  MEM_ARGS="-Xms128m -Xmx512m -XX:MaxPermSize=256m"
  if [ "x$USER_MEM_ARGS" != "x" ]; then
    MEM_ARGS="$USER_MEM_ARGS"
  fi

  # Setup the JVM
  if [ "x$JAVA_HOME" != "x" -a -x "$JAVA_HOME/bin/java" ]; then
    JAVA="$JAVA_HOME/bin/java"
  else
    print_err "Please specify a valid JAVA_HOME" >&2
    return 1
  fi

  # If -server not set in JAVA_OPTS, set it, if supported
  echo $JAVA_OPTS | grep "\-client" > $NullDevice 2>&1
  if [ "x$?" != "x0" ]; then
    echo $JAVA_OPTS | grep "\-server" > $NullDevice 2>&1
    if [ "x$?" != "x0" ]; then
      $JAVA -version | grep -i HotSpot > $NullDevice 2>&1
      if [ "x$?" != "x0" ]; then
        JAVA_OPTS="-server $JAVA_OPTS"
      fi
    fi
  fi

  echo $JAVA_OPTS | grep "\-server" > $NullDevice 2>&1
  if [ "x$?" = "x0" ]; then
    echo $JAVA_OPTS | grep "\-XX:[-\+]UseCompressedOops" > $NullDevice 2>&1
    if [ "x$?" != "x0" ]; then
      $JAVA -server -XX:+UseCompressedOops -version > $NullDevice 2>&1
      if [ "x$?" = "x0" ]; then
	JAVA_OPTS="$JAVA_OPTS -XX:+UseCompressedOops"
      fi
    fi

    echo $JAVA_OPTS | grep "\-XX:[-\+]TieredCompilation" > $NullDevice 2>&1
    if [ "x$?" != "x0" ]; then
      $JAVA -server -XX:+TieredCompilation -version > $NullDevice 2>&1
      if [ "x$?" = "x0" ]; then
	JAVA_OPTS="$JAVA_OPTS -XX:+TieredCompilation"
      fi
    fi
  fi

  if [ "x$JBOSS_MODULEPATH" = "x" ]; then
    JBOSS_MODULEPATH="$JBOSS_HOME/modules"
  fi
  
  if [ ! -d "$JBOSS_MODULEPATH" ]; then
    print_err "Directory '$JBOSS_MODULEPATH' not found.  Make sure jboss module directory exists and is accessible" >&2
    return 1
  fi
  
  read_property jboss.server.config.dir
  if [ "x$PropValue" = "x" ]; then
    SERVER_CONFIG_DIR="$ServerDir/configuration"
  else
    SERVER_CONFIG_DIR="$PropValue"
    if [ "x$SERVER_CONFIG_DIR" = "x$ServerDir/configuration" ]; then
      remove_property jboss.server.config.dir
    fi
  fi

  if [ ! -d "$SERVER_CONFIG_DIR" ]; then
    print_err "Directory '$SERVER_CONFIG_DIR' not found.  Make sure jboss config directory exists and is accessible" >&2
    return 1
  fi

  read_property jboss.server.data.dir
  if [ "x$PropValue" = "x" ]; then
    SERVER_DATA_DIR="$ServerDir/data"
  else
    SERVER_DATA_DIR="$PropValue"
    if [ "x$SERVER_DATA_DIR" = "x$ServerDir/data" ]; then
      remove_property jboss.server.config.dir
    fi
  fi
      remove_property jboss.server.config.dir

  if [ ! -d "$SERVER_DATA_DIR" ]; then
    print_err "Directory '$SERVER_DATA_DIR' not found, creating" >&2
    mkdir -p $SERVER_DATA_DIR
  fi

  read_property jboss.server.log.dir
  if [ "x$PropValue" = "x" ]; then
    SERVER_LOG_DIR="$ServerDir/log"
  else
    SERVER_LOG_DIR="$PropValue"
    if [ "x$SERVER_LOG_DIR" = "x$ServerDir/log" ]; then
      remove_property jboss.server.log.dir
    fi
  fi

  if [ ! -d "$SERVER_LOG_DIR" ]; then
    print_err "Directory '$SERVER_LOG_DIR' not found, creating" >&2
    mkdir -p "$SERVER_LOG_DIR"
  fi

  read_property jboss.server.temp.dir
  if [ "x$PropValue" = "x" ]; then
    SERVER_TEMP_DIR="$ServerDir/tmp"
  else
    SERVER_TEMP_DIR="$PropValue"
    if [ "x$SERVER_TEMP_DIR" = "x$ServerDir/tmp" ]; then
      remove_property jboss.server.temp.dir
    fi
  fi

  if [ ! -d "$SERVER_TEMP_DIR" ]; then
    print_err "Directory '$SERVER_TEMP_DIR' not found, creating" >&2
    mkdir -p "$SERVER_TEMP_DIR"
  fi

  read_property jboss.server.deploy.dir
  if [ "x$PropValue" = "x" ]; then
    SERVER_DEPLOY_DIR="$SERVER_DATA_DIR/content"
  else
    SERVER_DEPLOY_DIR="$PropValue"
    if [ "x$SERVER_DEPLOY_DIR" = "x$SERVER_DATA_DIR/content" ]; then
      remove_property jboss.server.deploy.dir
    fi
  fi

  if [ ! -d "$SERVER_DEPLOY_DIR" ]; then
    print_err "Directory '$SERVER_DEPLOY_DIR' not found, reating" >&2
    mkdir -p $SERVER_DEPLOY_DIR
  fi

  read_property org.jboss.boot.log.file
  if [ "x$PropValue" = "x" ]; then
    JAVA_OPTS="$JAVA_OPTS -Dorg.jboss.boot.log.file=$SERVER_LOG_DIR/boot.log"
  fi

  read_property logging.configuration
  if [ "x$PropValue" = "x" ]; then
    JAVA_OPTS="$JAVA_OPTS -Dlogging.configuration=file:$SERVER_CONFIG_DIR/logging.properties"
  fi

  # Setup JBoss specific properties
  JAVA_OPTS="-D[Standalone] $JAVA_OPTS"
  JAVA_OPTS="$JAVA_OPTS $MEM_ARGS"
  JAVA_OPTS="$JAVA_OPTS -Djboss.home.dir=$JBOSS_HOME"
  JAVA_OPTS="$JAVA_OPTS -Djboss.server.base.dir=$ServerDir"
  JAVA_OPTS="$JAVA_OPTS -jar $JBOSS_HOME/jboss-modules.jar"
  JAVA_OPTS="$JAVA_OPTS -mp $JBOSS_MODULEPATH"
  JAVA_OPTS="$JAVA_OPTS -jaxpmodule javax.xml.jaxp-provider"

  CommandName=$JAVA
  CommandArgs="$JAVA_OPTS org.jboss.as.standalone $JBOSS_OPTS"

  print_info $CommandName
  print_info $CommandArgs
}

###############################################################################
# Process node manager KILL command to kill the currently running server.     #
# Returns true if successful otherwise returns false if the server process    #
# was not running or could not be killed.                                     #
###############################################################################
do_kill() {
  read_java_pid
  if [ "x$?" != "x0" -o "x$srvr_pid" = "x" ]; then
    print_err "Jboss is not currently running" >&2
    return 1
  fi

  # Kill the server process
  write_state SHUTTING_DOWN:Y:N
  kill $srvr_pid

  # Now wait for up to $StopTimeout seconds for monitor to die
  count=0
  while [ $count -lt $StopTimeout ] && monitor_is_running; do
    sleep 1
    count=`expr ${count} + 1`
  done
  if monitor_is_running; then
    write_state FORCE_SHUTTING_DOWN:Y:N
    print_err "Server process did not terminate in $StopTimeout seconds after being signaled to terminate, killing" >&2
    kill -9 $srvr_pid
  fi
}

do_stat() {
  valid_state=0

  if read_file "$StateFile"; then
    statestr=$REPLY
    state=`echo $REPLY | sed 's/_ON_ABORTED_STARTUP//g'`
    state=`echo $state | sed 's/:.//g'`
  else
    statestr=UNKNOWN:N:N
    state=UNKNOWN
  fi

  if monitor_is_running; then
    valid_state=1
  elif java_is_running; then
    valid_state=1
  fi

  cleanup=N

  if [ "x$valid_state" = "x0" ]; then
    case $statestr in
      SHUTTING_DOWN:*:N | FORCE_SHUTTING_DOWN:*:N)
        state=SHUTDOWN
        write_state $state:Y:N
      ;;
      *UNKNOWN*) ;;
      *SHUT*) ;;
      *FAIL*) ;;
      *:Y:*)
        state=FAILED_NOT_RESTARTABLE
        cleanup=Y
      ;;
      *:N:*)
        state=FAILED_NOT_RESTARTABLE
        cleanup=Y
      ;;
    esac

    if [ "x$cleanup" = "xY" ]; then
      if server_is_started; then
        write_state $state:Y:N
      else
        write_state $state:N:N
      fi
    fi
  fi

  if  [ "x$InternalStatCall" = "xY" ]; then
    ServerState=$state
  else
    echo $state
  fi
}

###############################################################################
# run command.                                                                #
###############################################################################
do_command() {
    case $NMCMD in
    START)  check_dirs
            do_start
    ;;
    STARTP) check_dirs
            do_start
    ;;
    STAT)   do_stat ;;
    KILL)   do_kill ;;
    STOP)   do_kill ;;
    GETLOG) cat "$OutFile" 2>$NullDevice ;;
    TAILLOG) while true; do tail -100f "$OutFile" 2>$NullDevice; done ;;
    THREADDUMP) list_thread_dump ;;
    *)      print_err "Unrecognized command: $1" >&2 ;;
    esac
}


###############################################################################
# Prints command usage message.                                               #
###############################################################################
print_usage() {
  cat <<__EOF__
Usage: $0 [OPTIONS] CMD
Where options include:
    -h                                  Show this help message
    -D<name>[=<value>]                  Set a system property
    -b <host or ip>|<name>=<value>      Bind address for all JBoss services
    -m <ip>                             UDP multicast address
    -d <config name>                    Config name
__EOF__
}


PROGNAME=$0

AutoRestart=true
RestartMax=2
RestartDelaySeconds=0
LastBaseStartTime=0
NullDevice=/dev/null


###############################################################################
# Prerequirements
###############################################################################

if [ ! -x /sbin/fuser ]; then
  print_err "/sbin/fuser executable does not exist" >&2
  exit 1
fi

if [ "x$BASH" = "x" ]; then
  print_err "current shell is not a bash" >&2
  exit 1
fi

###############################################################################
# Parse command line options                                                  #
###############################################################################
eval "set -- $@"
while getopts hD:r:c:d:b:m: flag "$@"; do
  case $flag in
    h)
     print_usage
     exit 0
    ;;
    r)
     JBOSS_HOME=$OPTARG
    ;;
    c)
     ServerName=$OPTARG
    ;;
    D)
     JAVA_OPTS="$JAVA_OPTS -D$OPTARG"
    ;;
    b|d|m)
     JBOSS_OPTS="$JBOSS_OPTS -$flag $OPTARG"
    ;;
    *) print_err "Unrecognized option: $flag" >&2
     exit 1
    ;;
  esac
done

if [ ${OPTIND} -gt 1 ]; then
  shift `expr ${OPTIND} - 1`
fi

if [ $# -lt 1 ]; then
  print_err "Please specify a command to execute" >&2
  print_usage
  exit 1
fi

if [ "x$JBOSS_HOME" = "x" ]; then
  read_property jboss.home.dir
  if [ "x$PropValue" = "x" ]; then
    print_err "Please specify either jboss home (-r) or -Djboss.home.dir" >&2
    print_usage
    exit 1
  fi
  JBOSS_HOME="$PropValue"
fi

remove_property jboss.home.dir

if [ "x$ServerName" = "x" ]; then
  read_property jboss.server.base.dir
  if [ "x$PropValue" = "x" ]; then
    print_err "Please specify either jboss server name (-c) or -Djboss.server.base.dir" >&2
    print_usage
    exit 1
  fi
  ServerDir="$PropValue"
  ServerName=`basename -- "$ServerDir"`
else
  ServerDir=$JBOSS_HOME/server/$ServerName
fi

remove_property jboss.server.base.dir

NMCMD=`echo $1 | tr '[a-z]' '[A-Z]'`

OutFile=$ServerDir/log/$ServerName.out
PidFile=$ServerDir/nodemanager/$ServerName.pid
LockFile=$ServerDir/nodemanager/$ServerName.lck
StateFile=$ServerDir/nodemanager/$ServerName.state

if [ "x$RestartInterval" = "x" ]; then
  RestartInterval=10
fi

if [ "x$LogRotateSize" = "x" ]; then
  LogRotateSize=1073741824
fi

if [ "x$DeadlockDetectionInterval" = "x" ]; then
  DeadlockDetectionInterval=300
fi

if [ "x$StopTimeout" = "x" ]; then
  StopTimeout=60
fi

if [ "x$StartTimeout" = "x" ]; then
  StartTimeout=0
fi

do_command
