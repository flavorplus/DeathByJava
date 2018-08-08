#!/bin/sh
#
#
# Copyright (c) 2014-2017 Riverbed Technology, Inc. All rights reserved.
#
# -----------------------------------------------------------------------------
#
#  Description: Riverbed SteelCentral AppInternals Process Injection Control Tool.
#
#  Changes:
#
#  - Date   -  UID  --------------------- Description ---------------------
#  12/10/2014  rnm  Initial version.
#  12/11/2014  jwilson  bug fix for suse systems
#                       Changed tabs to spaces
#                       changed shebang to bash instead of sh
#                       Fixed indentation
#                       Changed if statements to [[ ]] structure
#                       Added libAwProfile64.so to install process
#                       Changed install to and from locations
# 01/02/2015  jwilson  logging verbosity
# 01/16/2015  rnm   Rename start => enable,  stop => disable.  Change processing of verbose.
#                   Change logging of syslog to only log when enabling or disabling injection.
# 02/17/2015  rnm   Class and method discovery support - add links to rpilj in root system libraries.
#                   Remove links to AwProfile in root system libraries.
#                   Remove redirecting output into log file (this will causes permission issues if 
#                   control script is run as a different user).
#                   Change help message to be similar to windows version.
#                   Cleanup output messages and make the text similar to windows when possible.
#                   Undocument verbosity parameter.
#                   Install process injection as "disabled" by default - cleanup messages with enabling and disabling.
#                   Add additional documentation.
#
# 06/11/2015  rnm   BUG 234782: Fix case where where librpil.so is not added to /etc/ld.so.preload if 
#                   /etc/ld.so.preload is empty.
# 12/02/2015  rnm   BUG 244127: Detect when process injection is not installed when enabling.  Make 
#                   "rpilctrl.sh install" a user-visible option.
# 12/02/2015  rnm   BUG 244127: Code review feedback.  Remove hard-coded script reference.
# 01/12/2016  rnm   Ubuntu support.
# 01/13/2016  rnm   Fix OS detection issue on Redhat.
# 01/22/2016  rnm   Support Ubuntu versions 12+ instead of Ubuntu 14+.
#                   Because the $LIB token differences between Ubuntu versions,  we need to use the $PLATFORM loader 
#                   token in ld.so.preload.   Unfortunately $PLATFORM for 32-bit libraries translate to i686 instead of
#                   i386,  so we need to install librpil into both /lib/i386-linux-gnu and /lib/i686-linux-gnu with 
#                   ubuntu.
#
#                   BUG 250762:  Fix issue where install script was improperly detecting SuSE as Ubuntu.
# 01/27/2016  rnm   Remove bogus "Unable to locate /lib/i686-linux-gnu/librpil.so" message that occurs when performing 
#                   "rpictrl.sh install" on Ubuntu.
#                   This code was suppose to verify that the install directory contains the 32-bit librpil.so (LIBRPIL_32_PATH),
#                   but that check was already done previously in the install_libraries() function.
# 02/18/2016  rnm   BUG 252298: Remove bash requirement for shell.   Remove all bash-isms from script to make script posix compliant.
#                   To make POSIX compliant,  we need to remove [[, ]] in favor of [, ] in conditional expressions,  remove the
#                   use of "local" in variable definitions,  specify standard error when redirectly output to /dev/null,
#                   use ` instead of $() to evaluate expression.
#
#                   Remove linux only commands in the part of the script that executes "rpictrl.sh status", since this 
#                   will also be launched from the DSA on non-linux systems to report status to the analysis server.
#                   Change the output of "rpictrl status" to include "Start type:" and "Status" to stay consistent with 
#                   windows and allow common parsing of output for the DSA.   Make sure the disable/uninstall/install is 
#                   is not allowed on non-linux OS.
# 10/18/2016  rnm   BUG 252298: Support Amazon AMI Linux. 
# 11/29/2016  rnm   BUG 273229: Remove bashism introduced in previous checkin.   Remove use of lsb_release since this may not be
#                   present in an ubuntu docker container.  If unable to load the preloaded library, make sure the install fails.
#                   Make sure grep from /bin is used.
# 01/27/2017  rnm   BUG 273229: Use /etc/lsb-release if /etc/os-release is not present (ie Ubuntu 12) to check for linux distribution.  
#                   Do not return error on an uninstall if we are running on unsupported process injection platform.   This will 
#                   allow the agent uninstall to work even if we are uninstalling on an unsupported process injection platform. 
#                   Remove version checks for Ubuntu since the agent install already takes care of this.  Process injection already
#                   checks for a minimum loader version. 
# 01/27/2017  rnm   BUG 273229: Implement code review comments.  Only check for /etc/lsb-release or /etc/os-release if checking for Ubuntu
#                   and Amazon distributions.  Log debug messsages if /etc/os-release and /etc/lsb-release not found.
# 01/27/2017  rnm   Support Debian platform which is treated much the same as Ubuntu.   
# 02/09/2017  rnm   Code review comments.  Remove duplicate LIB32_DIR definitions.
#
#------------------------------------------------------------------------------

# Echo error message to stderr.
#
err()
{
  echo "$@" >&2
}

# Log status information to console.
#
log_status()
{
  echo "$@"
}

# Log information only if verbose is enabled.
#
log()
{
  if [ -n "$VERBOSITY" ]; then
    echo "$@"
  fi
}

# Echo message to syslog and standard output.
#
syslog()
{
  logger "$@"
  log_status "$@"
}

# Make sure our effective user id is root.
# return 0 if root.
#        1 if non-root.
#
check_for_root_user()
{
  ret=0
  userid=`id -u`
  if [ "$userid" -ne 0 ]; then
    ret=1
    err "Error $1 process injection. Root access required."
  else
    log "Root check succeeded"
  fi

  return $ret
}

# Install library.
# $1 Source directory containing library.
# $2 Destination directory.
#
# return 0 if install is successful.  non-zero otherwise.
#
install_lib()
{
  src_lib=$1
  dest_dir=$2
  ret=0
  dest_lib=${dest_dir}/${LIBRPIL}

  log "Install library ${dest_lib}"
  cp ${src_lib} ${dest_lib}
  ret=$?

  if [ "${ret}" -ne 0 ]; then
    err "Unable to copy ${src_lib} ${dest_lib}"
  else
    chmod ${LIBPERMISSION} ${dest_lib}
    ret=$?
    if [ "${ret}" -ne 0 ]; then
      err "Unable to set %{dest_lib}"
      unlink ${dest_lib}
    fi
  fi
  log "Installed ${LIBRPIL} to ${dest_lib}"
  return ${ret}
}

# Uninstall library from system.
#
# $1 - Directory path to process injection library.
#
# return 0 if uninstall is successful.  non-zero otherwise.
#        
uninstall_lib()
{
  source_dir=$1
  ret=0
  lib=${source_dir}/${LIBRPIL}

  if [ -f "${lib}" ]; then
    log "Uninstall ${lib}"
    unlink ${lib}
    stat=$?
    ret=`expr $ret + $stat`
    if [ ${stat} -ne 0 ]; then
      err "Unable to uninstall ${lib}, status: ${rc}"
    fi
  else
    log "${lib} not currently installed."
  fi
  return ${ret}
}

# Verify presence of file.
# $1 - file path
#
# Return 0 if file is present.  1 if file not present.
#
verify()
{
  if [ -f $1 ]; then
    # log "$1 is present"
    return 0
  else
    err "Unable to locate $1"
    return 1
  fi
}

# Install the 32 and 64 bit librpil libraries.
#
# return 0 if successfully installed libraries. non-zero if error.
#
install_libraries()
{
  ret=0
  test_load $LIBRPIL_64_PATH
  
  # if the test_load failed,  do not install the library.
  #
  if [ $? -ne 0 ]; then
    return 1
  fi

  # add 32 bit library directory if the directory is missing.  We need to make certain that 
  # our preload library is installed even if there is nothing 32-bit that is pre-existing on the 
  # system.   Otherwise,  subsequent 32-bit installs of applications will look will not find the 
  # preloaded library.
  #
  if [ ! -d $LIB32_DIR ] ; then
      $MKDIR $LIB32_DIR
      $CHMOD $LIBPERMISSION $LIB32_DIR
      log "Created $LIB32"
  fi

  # On unbuntu, we need to install install the 32-bit rpil module in in /lib/i686-linux-gnu in
  # addition to /lib/i386-linux-gnu.   This will allow 32-bit modules to loaded via /etc/ld.so.preload.
  # since the PLATFORM loader token translates to i686.
  #
  if [ -n "$LIB686_DIR" ] && [ ! -d $LIB686_DIR ] ; then
      $MKDIR $LIB686_DIR
      $CHMOD $LIBPERMISSION $LIB686_DIR
      log "Created $LIB686"
  fi

  verify $LIBRPIL_32_PATH
  ver=$?
  if [ $ver -eq 0 ]; then
    install_lib ${LIBRPIL_32_PATH} ${LIB32_DIR}
    ret=$?
    verify $LIBRPIL_64_PATH
    ver=$?
    if [ "${ret}" -eq 0 ] && [ $ver -eq 0 ]; then
      install_lib ${LIBRPIL_64_PATH} ${LIB64_DIR}
      ret=$?
      verify $LIBRPILJ_64_PATH
      ver=$?
      if [ "${ret}" -eq 0 ] && [ $ver -eq 0 ]; then
        ln -s ${LIBRPILJ_64_PATH} ${LIB64_DIR}/${LIBRPILJ}
        ret=$?
        verify $LIBRPILJ_32_PATH
        ver=$?
        if [ "${ret}" -eq 0 ] && [ $ver -eq 0 ]; then
          ln -s ${LIBRPILJ_32_PATH} ${LIB32_DIR}/${LIBRPILJ}
          ret=$?
          if [ "${ret}" -eq 0 ]; then 
            # Install 32-bit rpil library on debian system. This is where the 32-bit rpil will be preloaded.
            if [ -n "$LIB686_DIR" ]; then
              install_lib  ${LIBRPIL_32_PATH} ${LIB686_DIR}
              ret=$?
              if [ ${ret} -eq 0 ]; then
                log "Successfully installed all rpil components on debian system."
              else
                err "Failed to install ${LIB686_DIR}/${LIBRPIL}"
                uninstall_lib ${LIB32_DIR}
                uninstall_lib ${LIB64_DIR}
                unlink ${LIB64_DIR}/${LIBRPILJ} > /dev/null 2>&1
                unlink ${LIB32_DIR}/${LIBRPILJ} > /dev/null 2>&1
              fi
            else
                log "Successfully installed all rpil components on fedora system."
            fi
          else
            err "Failed to link ${LIBRPILJ_32_PATH} to ${LIB32_DIR}/${LIBRPILJ}"
            uninstall_lib ${LIB32_DIR}
            uninstall_lib ${LIB64_DIR}
            unlink ${LIB64_DIR}/${LIBRPILJ} > /dev/null 2>&1
            unlink ${LIB32_DIR}/${LIBRPILJ} > /dev/null 2>&1
          fi
        else
          err "Failed to link ${LIBRPILJ_32_PATH} to ${LIB32_DIR}/${LIBRPILJ}"
          uninstall_lib ${LIB32_DIR}
          uninstall_lib ${LIB64_DIR}
          unlink ${LIB64_DIR}/${LIBRPILJ} > /dev/null 2>&1
        fi
      else
        err "Failed to link ${LIBRPILJ_64_PATH} to ${LIB64_DIR}/${LIBRPILJ}"
        uninstall_lib ${LIB32_DIR}
        uninstall_lib ${LIB64_DIR}
      fi
    else
      err "Failed to install ${LIBRPILJ_64_PATH}"
      uninstall_lib ${LIB32_DIR}
    fi
  else
    err "Failed to install ${LIBRPILJ_32_PATH}"
  fi
  return ${ret}
}

# Uninstall the 32 and 64 bit process injection system libraries.
#
# Return 0 if successfully uninstalled.  Non-zero otherwise.
#
uninstall_libraries()
{
  rc=0
  log "Uninstall 32 and 64 bit rpil libraries."
  uninstall_lib ${LIB32_DIR}
  rc=$?
  if [ "${rc}" -eq 0 ]; then
    uninstall_lib ${LIB64_DIR}
    rc=$?
    if [ "${rc}" -eq 0 ]; then
      if [ -n ${LIB686_DIR} ]; then    
        uninstall_lib ${LIB686_DIR}
        rc=$?
      fi
      if [ "${rc}" -eq 0 ]; then
        unlink ${LIB64_DIR}/${LIBRPILJ} > /dev/null 2>&1
        unlink ${LIB32_DIR}/${LIBRPILJ} > /dev/null 2>&1
        log "Successfully uninstalled all rpil components"
      fi
    fi
  fi

  return ${rc}
}

# Try to load the library into a process and make sure the process does not die.
#
# $1 library name.
# TODO russ - testload 32-bit application.
#
# Return 0 if application can load with our preloaded library.  1 if not.
#
test_load()
{
  lib=${1}
  dependency=
  ret=0
  log "Test load ${lib}"

  before_preload=`/bin/uname`
  # Test load a simple application to make sure our library can load on the system.
  #
  after_preload=`LD_PRELOAD=${lib} /bin/uname 2>&1`
  ret=$?

  if [ "${after_preload}" =  "${before_preload}" ]; then
    log "Application successful when LD_PRELOAD=${lib}"

    dependency=` LD_PRELOAD=${lib} ldd /bin/uname | $GREP ${lib} `
    if [ -n "${dependency}" ]; then
      log "Application successfully loaded library ${lib}"
    else
      err "${lib} was not loaded into /bin/uname"
      ret=$RPIL_CANNOT_LOAD
    fi
  else
    err "Unable to load /bin/uname with ${lib}.  Return status: ${ret}"
    ret=$RPIL_CANNOT_LOAD
  fi

  return ${ret}
}

# Validate libraries that we will install exist and can load.   Note for
# now we only test load the 64 bit version.
# $1 - lib32 system library directory.
# $2 - lib64 system library directory.
#
# return 0 if the libraries installed/valid.  RPIL_CANNOT_LOAD if we cannot load the library. RPIL_NOT_INSTALLED if library not installed.
validate_libraries()
{
  rc=0
  lib32_directory=$1
  lib64_directory=$2

  if [ ! -f $lib32_directory/$LIBRPIL ]; then
    log "$lib32_directory/$LIBRPIL not found.".
    rc=$RPIL_NOT_INSTALLED
  else
    log "Found $lib32_directory/$LIBRPIL"
  fi

  if [ ! -f $lib64_directory/$LIBRPIL ]; then
    log "$lib64_directory/$LIBRPIL not found.".
    rc=$RPIL_NOT_INSTALLED
  else
    log "Found $lib64_directory/$LIBRPIL"

    test_load $lib64_directory/$LIBRPIL
    rc=$?
  fi

return ${rc}
}

# Remove process injection library entry from /etc/ld.so.preload
# return 0 if rpil we removed. 
#        non-zero status indicates failure.  
#
remove_rpil_from_preload()
{
  tmpfile=`mktemp_preload`
  ret=$?

  if [ $? -eq 0 ]; then
    chmod ${LD_SO_PRELOAD_PERM}  ${tmpfile}

  # Remove rpl library and remove leading whitespace from file.
  #
  sed "s,${RPIL_PRELOAD},,g" ${LD_SO_PRELOAD} |  sed 's/^[ \t]*//' >  ${tmpfile}
  ret=$?

  if [ "${ret}" -eq 0 ]; then
    if [ ! -w  "${LD_SO_PRELOAD}" ]; then
      err "No write access to ${LD_SO_PRELOAD}.   Attempting to grant write access"
      chmod +w  "${LD_SO_PRELOAD}"
    fi

    cp  ${tmpfile} ${LD_SO_PRELOAD}
    ret=$?

    if [ "${ret}" -eq 0 ]; then
      log "Updated ${LD_SO_PRELOAD} to remove ${RPIL_PRELOAD}"
      chmod ${LD_SO_PRELOAD_PERM}  ${LD_SO_PRELOAD}
    else
      err  "Unable to update ${LD_SO_PRELOAD} to remove ${RPIL_PRELOAD}"
    fi

    chmod ${LD_SO_PRELOAD_PERM}  ${LD_SO_PRELOAD}

    log "Removed ${RPIL_PRELOAD} from ${LD_SO_PRELOAD}. "
    remove_empty_preload
  else
    err "Unable to remove  ${RPIL_PRELOAD} from ${LD_SO_PRELOAD}. "
  fi

  rm -f  ${tmpfile}
else
  err "Unable to create temp file to hold copy of ${LD_PRELOAD_SO}."
fi

return ${ret}
}

# If there are no libraries listed in ld.so.preload, remove the file.
# return 0 if rpil was added as a preloaded library. 
#        non-zero status indicates failure.  
#
remove_empty_preload()
{
  nonwhitespace=`sed 's/[[:space:]|:|[:cntrl:]]//g' ${LD_SO_PRELOAD} | awk '{if(length() > 0){print length()}}'`
  ret=$?

  if [ ${ret} -eq 0 ] && [ -z "${nonwhitespace}" ]; then
    log "Deleting ${LD_SO_PRELOAD}"
    rm -r ${LD_SO_PRELOAD}
    if [ $? -ne 0 ]; then
      log "Unable to remove ${LD_SO_PRELOAD}"
    fi
  fi

}

# Add process injection library to /etc/ld.so.preload.
# return 0 if rpil was added as a preloaded library. 
#        non-zero status indicates failure.  
add_rpil_to_preload()
{
  tmpfile
  tmpfile=`mktemp_preload`
  ret=$?


  if [ ! -w  "${LD_SO_PRELOAD}" ]; then
    err "No write access to ${LD_SO_PRELOAD}.   Attempting to grant write access"
    chmod +w  ${LD_SO_PRELOAD}
  fi

  # Add Process injection library before any other library that is listed on the first line.   The END clause is required in
  # in case there are no records in the file. 
  #
  awk -v "RPIL_PRELOAD=${RPIL_PRELOAD}" '{
                                          if (NR == 1) 
                                             {print RPIL_PRELOAD " " $0} 
                                          else 
                                             {print $0} 
                                         } 
                                         END {
                                          if (NR == 0) 
                                             {print RPIL_PRELOAD " "}  
                                         }' ${LD_SO_PRELOAD} > ${tmpfile}
  ret=$?

  if [ "${ret}" -eq 0 ]; then

    cp  ${tmpfile} ${LD_SO_PRELOAD}
    ret=$?

    if [ "${ret}" -eq 0 ]; then
      log "Updated ${LD_SO_PRELOAD}"
      chmod ${LD_SO_PRELOAD_PERM}  ${LD_SO_PRELOAD}
    else
      err  "Unable to update ${LD_SO_PRELOAD}"
    fi
  else
    err "Unable to add ${RPIL_PRELOAD} to  ${LD_SO_PRELOAD}"
  fi

  rm -f ${tmpfile}

  return ${ret}
}

# Check /etc/ld.so.preload to see if process injection library is present.
# return 0 if rpil is preloaded. 1 if rpil not being preloaded.
#
is_rpil_preloaded()
{
  ret=1
  if [ -f  ${LD_SO_PRELOAD} ]; then

    rpil_preloaded=""
    rpil_preloaded=`$GREP ${RPIL_PRELOAD} ${LD_SO_PRELOAD} `

    if [ $? -eq 0 ] && [ -n "${rpil_preloaded}" ]; then
      ret=0
    fi
  fi

  return ${ret}
}

# Disable process injection.
# return 0 if process injection is successfully disabled.
#        1 if could not disable process injection.
#
disable_injecting()
{
  log "Disable process injection.."
  ret=0
  already_disabled="Process injection already disabled."
  check_for_root_user disabling
  ret=$?
  if [ "${ret}" -eq 0 ]; then

    if [ -f "${LD_SO_PRELOAD}" ]; then
      is_rpil_preloaded
      if [ $? -eq 0 ]; then
        remove_rpil_from_preload
        ret=$?
        if [ "${ret}" -eq 0 ]; then
          syslog "Successfully disabled process injection."
        else
          err "Error disabling process injection."
        fi
      else
        ret=0
        log_status "$already_disabled"
      fi
    else
      log_status "$already_disabled"
    fi
  fi
  
  return ${ret}
}

# Enable process injection.
# return 0 if process injection successfully enabled..
#        1 if could not enable process injection.
#
enable_injecting()
{
  log "Enable process injection."
  ret=0
  check_for_root_user enabling
  ret=$?
  if [ "${ret}" -eq 0 ]; then
    if [ -f "${LD_SO_PRELOAD}" ]; then
      is_rpil_preloaded
      if [ $? -ne 0 ]; then
        add_rpil_to_preload
        ret=$?
        if [ "${ret}" -eq 0 ]; then
          syslog "Successfully enabled process injection."
        else
          err "Error enabling process injection."
        fi
      else
        log_status "Process injection already enabled."
      fi
    else
      echo "${RPIL_PRELOAD} " > ${LD_SO_PRELOAD}
      ret=$?
      if [ "${ret}" -eq 0 ]; then
        chmod ${LD_SO_PRELOAD_PERM}  ${LD_SO_PRELOAD}
        syslog "Successfully enabled process injection."
      else
        err "Error enabling process injection"
      fi
    fi
  fi

  return ${ret}
}

# Remove process injection library from ld.so.preload
# Remove process injection libraries from from system directories.
#
# Return 0 if successfully uninstalled.  Non-zero otherwise.
#
uninstall_rpil()
{
  log "Uninstall Process Injection Library"
  check_for_root_user uninstalling
  rc=$?
  if [ "${rc}" -eq 0 ]; then
    disable_injecting
    rc=$?
    if [ "${rc}" -eq 0 ]; then
      uninstall_libraries
      rc=$?
    fi
  fi
  
  if [ "${rc}" -eq 0 ]; then
    log_status "Successfully uninstalled process injection library."
   else
    err "Failed to uninstall process injection library "
  fi
  
  return ${rc}
}

# Install process injection library.
#
# Return 0 if successfully installed.  Non-zero otherwise.
#
install_rpil()
{
  log "Install process injection library..."

  rc=0
  check_requirements
  rc=$?

  if [ ${rc} -eq 0 ]; then
    # validate_libraries $LIB32_INST_DIR $LIB64_INST_DIR
    # rc=$?
    if [ ${rc} -eq 0 ]; then
      uninstall_rpil
      rc=$?
      if [ ${rc} -eq 0 ]; then
        install_libraries
        rc=$?
      fi
    fi
  fi

  if [ "${rc}" -eq 0 ]; then
    log_status "Successfully installed process injection library."
   else
    err "Failed to install process injection library. "
  fi
 
  return ${rc}
}

# Check system requirements.
#
# Return 0 if system passes requirements for installing process injection. Non-zero otherwise.
#
check_requirements()
{
  ret=0
  check_os
  ret=$?
  if [ $ret -eq 0 ]; then
    check_arch
    ret=$?
    if [ $ret -eq 0 ]; then
      check_libc
      ret=$?
    fi 
  fi

  return ${ret}
}

# Check libc version.  2.4 is required.
#
# return 0 if libc version is supported.
# return 1 if libc version is unsupported.
#
check_libc()
{
  log "Check for correct libc version."

  ret=0
  libcversion=`ldd --version | awk -F')' '{if (NR==1){print $2}}'`
  libcmajor=`echo $libcversion | awk -F. '{print $1}'`
  libcminor=`echo $libcversion | awk -F. '{print $2}'`

  log "Detected libc version: $libcversion libc major: $libcmajor minor $libcminor "

    # Must be libc version 2.4+
    #
    if [ $libcmajor -eq 2 ] && [ $libcminor -ge 4 ]; then
      log "The version of libc version supported."
    else
      err "The version of libc version unsupported."
      ret=1
    fi

    ret=${ret}
  }

# Check architecture version.
#
# return 0 if installed on a 64 bit system.  1 if not 64 bit.
#
check_arch()
{
  log "Check system architecture."
  rc=1
  case `uname -m` in
    x86_64)
    log "x86_64 is detected and supported."
    ret=0
  ;;
    i*86)
    err "Failure!:  32 bit unsupported."
  ;;
    *)
    err "Failure!: unsupported architecture ."
  ;;
  esac

  return ${ret}
}

# Check os version.  Redhat, suse and centos are supported.
#
# Return 0 if supported.   1 if not supported.
#
check_os()
{
  log "Check Linux distribution type."

  ret=0

  if [ -f /etc/centos-release ]; then
    log "Centos Linux detected and is supported."
  elif [ -f /etc/redhat-release ]; then
    log "Redhat Linux detected and is supported."
  elif [ -f /etc/SuSE-release ]; then
    log "SUSE Linux detected and is supported. "
  else 
     check_debian
     if [ $? -ne 0 ]; then 
       is_AmazonAMI
       if [ $? -ne 0 ]; then
         err "Failure:  OS unsupported.  Centos, Redhat, SUSE, Ubuntu, Amazon AMI Linux are required."
         ret=1
       fi
     fi
  fi

  return ${ret}
}

# Check OS id to identify the linux distribution.
#
# $1 os id to check.
# $2 fully qualified linux distribution name.
#
# Return 0 if matches desired id.   1 if not.
#
is_osid()
{
  os_rel=$1
  ret=1
  establish_os_identity_file
  
  # Only verify OS id if either /etc/lsb-realease or /etc/os-release 
  # is present.   Note that not all Linux distributions contain these files.
  #
  if [ -n "$OS_RELEASE_FILE" ]; then
    DESIRED_ID=${ID_STRING}${os_rel} 
    log "Check for $2 by checking for $DESIRED_ID in $OS_RELEASE_FILE."
    id=`$GREP -i $DESIRED_ID $OS_RELEASE_FILE 2>/dev/null `
    ret=1

    if [ -n "$id" ]; then
      log "$2 Linux detected"
      ret=0
    fi
  else
    log "Not $2 Linux - both /etc/lsb-release and /etc/os-release are missing."
  fi

  return ${ret}
}

# Check if we are running on Amazon AMI Linux.
#
# Return 0 if Amazon AMI Linux.   1 if not.
#
is_AmazonAMI()
{
  is_osid '"amzn"' "Amazon AMI"
  return $?
}

# Check to see if we are running on ubuntu.
#
# Return 0 if Ubuntu.   1 if not.
#
is_ubuntu()
{
  is_osid "ubuntu" "Ubuntu"
  return $?
}

# Check to see if we are running on debian.
#
# Return 0 if Debian.   1 if not.
#
is_debian()
{
  is_osid "debian" "Debian"
  return $?
}

# Establish os identity file.  Some distributions use /etc/lsb-release (Ubuntu 12), /etc/os-release
# is more common.
#
# Return N/A
#
establish_os_identity_file()
{
  if [ -f /etc/os-release ]; then
     OS_RELEASE_FILE=/etc/os-release
	 ID_STRING=ID=
  elif [ -f /etc/lsb-release ]; then
     OS_RELEASE_FILE=/etc/lsb-release
     ID_STRING=DISTRIB_ID=
  else
     OS_RELEASE_FILE=
	 ID_STRING=
  fi
}

# Check for a ubuntu and debian and set library file locations.  Both ubuntu and debian have different library
# locations when compared to fedora systems.
#
# Return 0 if Debian(including Ubuntu) based.   1 if not.
#
check_debian()
{
  log "Check for Ubuntu/Debian distribution."
  ret=1

  is_ubuntu
  if [ $? -eq 0 ]; then
	ret=0
  else
    is_debian
	if [ $? -eq 0 ]; then
	  ret=0
    else
      log "OS is not Ubuntu or Debian."
	fi
  fi
  
  if [ $ret -eq 0 ]; then
    log "Debian based OS detected."
	
    # Debian libraries are installed into a different location.
    #
    LIB686_DIR=/lib/i686-linux-gnu
    LIB32_DIR=/lib/i386-linux-gnu
    LIB64_DIR=/lib/x86_64-linux-gnu
    # To support Ubuntu 12.x/Debian 7.x and 14.x/Debian 8+, We remove loader token in the librpil.so path in ld.so.preload.   
	# This is because $LIB behaves differently on Ubuntu 12/Debian 7 vs Ubuntu 14+/Debian 8+.  Since we install
    # librpil.so on both 64-bit and 32-bit root libraries,  it will hopefully be able to to find the library regardless of architecture (32-bit vs. 64-bit).
    #
    RPIL_PRELOAD=/lib/\${PLATFORM}-linux-gnu/${LIBRPIL}
  fi

  return ${ret}
}

# Create a temporary file to construct ld.so.preload copy.
#
# Return 0 if files sucessfully created.  Non-zero otherwise.
#
mktemp_preload()
{
  ret=0
  temp_preload=`mktemp`
  ret=$?
  echo "${temp_preload}"
  return ${ret}
}

# Shows help related to using this tool.
#
showhelp()
{
  $ECHO ""
  $ECHO "Riverbed SteelCentral AppInternals Process Injection Control"
  $ECHO ""
  $ECHO "USAGE:\t$(basename "$0") [enable | disable | status | install]"
  $ECHO ""
  $ECHO "WHERE:"
  $ECHO "\tenable   - Enables process injection"  
  $ECHO "\tdisable  - Disables process injection" 
  $ECHO "\tstatus   - Gets the status of process injection"
  $ECHO "\tinstall  - Installs process injection"
  $ECHO ""
  $ECHO "EXAMPLES:"
  $ECHO "\t$(basename "$0") enable" 
  $ECHO "\t$(basename "$0") disable" 
  $ECHO "\t$(basename "$0") status" 
  $ECHO "\t$(basename "$0") install" 
  $ECHO ""
}

# Get the fully qualified path of the executing script.
#
get_script_dir()
{
  savedir=`pwd`
  scriptdir=`dirname "$0"`
  cd $scriptdir
  SCRIPTPATH=`pwd`
  cd $savedir   
}

# Main entry point for this tool.
#
main()
{
  ETC=/etc
  LIBRPIL=librpil.so
  LD_SO_PRELOAD=${ETC}/ld.so.preload
  # Uncomment the following line for easy development testing.
  #  LD_SO_PRELOAD=ld.so.preload.tmp
  exitcode=0
  get_script_dir
  LIB64_INST_DIR=${SCRIPTPATH}/obj
  LIBRPIL_64_PATH=${SCRIPTPATH}/../lib/librpil64.so
  LIBRPIL_32_PATH=${SCRIPTPATH}/../lib/librpil.so
  LIBRPILJ_NAME=librpilj
  LIBRPILJ=${LIBRPILJ_NAME}.so
  LIBRPILJ_64_PATH=${SCRIPTPATH}/../lib/${LIBRPILJ_NAME}64.so
  LIBRPILJ_32_PATH=${SCRIPTPATH}/../lib/${LIBRPILJ}
  LIB32_INST_DIR=${SCRIPTPATH}/obj32
  LIBPERMISSION=755
  LD_SO_PRELOAD_PERM=644
  LIB32_DIR=/lib
  LIB64_DIR=/lib64
  RPIL_PRELOAD=/\$LIB/${LIBRPIL}
  AWK=/usr/bin/awk
  MKDIR=/bin/mkdir
  CHMOD=/bin/chmod
  ECHO="/bin/echo -e"
  CP=/bin/cp
  RM=/bin/rm
  GREP=/bin/grep
  VERBOSITY=`echo $@ | grep verbose `
  COMMAND=`echo $@ | sed s/-//g | sed s/verbose//g | awk '{print $1}' `
  RPIL_NOT_INSTALLED=2
  RPIL_CANNOT_LOAD=1
  LIB686_DIR=

  # See how we were called.
  case $COMMAND in
        
    install)
    install_rpil
    exitcode=$?
    ;;

    uninstall)
    check_os
    if [ $? -eq 0 ]; then
      uninstall_rpil
      exitcode=$?
    fi;
    ;;

    enable)
    check_os
    exitcode=$?
    if [ $exitcode -eq 0 ]; then
      validate_libraries $LIB32_DIR $LIB64_DIR
      exitcode=$?
      if [ ${exitcode} -eq 0 ]; then
        enable_injecting
        exitcode=$?
      elif [ ${exitcode} -eq $RPIL_NOT_INSTALLED ]; then
         script=`basename "$0"`
         err "Error: Process injection is not installed.  Run \"$script install\" before \"$script enable\"."
      else
        err "Error enabling process injection."
      fi;
    fi;
    ;;

    disable)
    check_os
    exitcode=$?
    if [ ${exitcode} -eq 0 ]; then
      disable_injecting
      exitcode=$?
    fi;
    ;;

    status)
    check_os
    exitcode=$?
    if [ ${exitcode} -eq 0 ]; then
      is_rpil_preloaded
      exitcode=$?
    fi
    # Output must contain Start type: and Status: value to stay consistent with windows to give a 
    # common output format to the DSA.
    #
    if [ ${exitcode} -eq 0 ]; then
      log_status "Start type: system start"
      log_status "Status: running"
    else
      log_status "Start type: disabled"
      log_status "Status: stopped"
    fi
      ;;

    *)
    showhelp
    exitcode=1

  esac

  return $exitcode
}


main "$@"
