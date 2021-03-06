#!/bin/bash
##
# @name: configure_controller.sh
# @version: 1.1
# @date: 02/02/2017
# @author: Gregory Callea gcallea@auctacognitio.net
#
##

#Parameters
#===========

#Global
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
FILE_NAME=`basename "$0"`

#Input

internalIP='{{ansible_ssh_host}}'
publicIP='{{publicIP}}'
apiV2User='{{apiV2User}}'
apiV2Password='{{apiV2Passwd}}'
apiV1Key='{{apiV1Key}}'
apiV1Password='{{apiV1Passwd}}'
serverGroup='{{groupID}}'
serverNetwork='{{networkID}}'
serverRootPassword='{{rootPasswd}}'
#controlAlias="{{ lookup('env','CLC_ACCT_ALIAS') }}"   -  unneeded

#Runner Job
platformRepoURL="https://github.com/c3dnadev/c3dna-aem-platform"
platformRepoBranch="master"
platformRepoPlaybook="playbook.yml"

#Vps
VPS_LN=ctl.bp.aem.c3dna.net
vpsURL="http://$VPS_LN/adobe-aem"
vpsConfFile="controllerIndex.txt"

#Download Index File
wget $vpsURL/$vpsConfFile -P .

#User
OWNER=cccuser
DEFAULT_CCCUSER_PASSWORD=cccDNA2013!
NEW_CCCUSER_PASSWORD=$serverRootPassword
USER_HOME=/home/$OWNER

#Software
CCC_HOME=$USER_HOME/ccc
BLUEPRINT_DIR=$USER_HOME/blueprint_c3dna_ext/
echo $DEFAULT_CCCUSER_PASSWORD | sudo -Sp "" -u $OWNER mkdir -p $BLUEPRINT_DIR

LOGFILE=$BLUEPRINT_DIR/ctl_configure.log
CONF_FILE=$BLUEPRINT_DIR/conf.json

#Commons
USER_PATH=$(pwd)
USER_NAME=$(whoami)
CONTENT=$(find /home/)

#=========================================================================
#The print function goes to write log on stdout and on file
#=========================================================================
function print(){

   local line=$1

   if [[ $line == *ERROR* ]]
   then
     line="$line. Check logs at $LOGFILE for details"
     echo -e $line | tee -a $LOGFILE
     exit 1;
   else
     echo -e $line &>> $LOGFILE
   fi

}

#=========================================================================
#The timestamp function returns timestamp using the following format:
#<YEAR>_<MONTH_DAY>_<HOUR>_<MINUTES>_<TIMEZONE>
#=========================================================================
timestamp(){

  TIMESTAMP=$(date +%Y_%m_%d_%H_%M)

}

#=========================================================================
#The initLog function goes to initialize the log file
#=========================================================================
function initLog(){

   echo "" > $LOGFILE
   timestamp
   print "########\b CTL BP Configuration \n Execution: $TIMESTAMP\n########"

}

#=========================================================================
#The restoreResolvConf function goes to restore the resolv.conf to be a symbolic link of /run/resolvconf/resolv.conf
#=========================================================================
function restoreResolvConf(){

#Restore resolv.conf as symbolic link to /etc/resolv.conf
rm /etc/resolv.conf
ln -s /run/resolvconf/resolv.conf /etc/resolv.conf

}

#=========================================================================
#The replace_line_statemachine function
#@Usage : replace_line_statemachine "<key>" "<key> = <value>" <FILE>
#@Example: replace_line_statemachine "DHT.enable" "DHT.enable = true" $CCC_DIR/conf/include/UI.properties
#=========================================================================
function replace_line_statemachine(){

  KEY=$1
  NEW_LINE=$2
  FILE=$3
  MODE=$4

  foundentry=false

  i=0
  while read -r line || [[ -n "$line" ]]; do
     i=$((i+1))
     if [[ $line == *$KEY* ]]
     then
       sudo sed -i "$i s@.*@$NEW_LINE@" $FILE
       foundentry=true
     fi

  done < $FILE

  if [[ $foundentry == false ]]
  then
    if [[ $MODE == "warn" ]]
    then
      print_both "WARN: unable to find $KEY entry on $FILE"
    else
      print_both "ERROR: unable to find $KEY entry on $FILE"
    fi
  fi
}


#=========================================================================
#The getLocationAlias function goes to get instance related Location on Century Link sending POST via API V1
#=========================================================================
function getLocationAlias(){

   parameters='{"APIKey":"'$apiV1Key'","Password":"'$apiV1Password'"}'

   cookieFile=ctlCookieV1.txt
   print "Executing login on CTL API v1 with parameters: $parameters"

   RESPONSE=$(curl -X POST -d $parameters https://api.ctl.io/REST/Auth/Logon/ --header "Content-Type:application/json" -c $cookieFile)
   print "Response is: $RESPONSE"

   if [[ $RESPONSE != *'"Success":true'* ]]
   then
     print "ERROR: provided API V1 Credentials are not correct. Blueprint creation interrupted"
   else
     print "Login on API V1 Credentials has been executed correctly"
   fi

   #Get Location
   print "Get Location for instance [$HOSTNAME]"
   parameters='{"Name":"'$HOSTNAME'"}'
   RESPONSE=$(curl -X POST -d $parameters https://api.ctl.io/REST/Server/GetServer/ --header "Content-Type:application/json" -b $cookieFile)
   print "Response is: $RESPONSE"

   success=$(echo $RESPONSE | grep -o -P '(?<=Success":).*?(,)' | tr -d ,)
   if [[ $success == true ]]
   then
     locationAlias=$(echo $RESPONSE | grep -o -P '(?<=Location":").*?(")' | tr -d \" | tr -d \')
     print "location is $locationAlias"

     if [ -z $locationAlias ]
     then
       print "ERROR: request has been executed correctly, but detected location feor instance [$HOSTNAME] is empty"
     fi
   else
     print "ERROR: unable to get location for instance [$HOSTNAME]"
   fi
}

#=========================================================================
#The updatePlaceholder function updates a placeholder on a specific file
#=========================================================================
function updatePlaceholder(){

    local parameter=$1
    local value=$2
    local file=$3

    print "#### Updating [$parameter] with value [$value] on file [$file] ( owner: $OWNER - password: $DEFAULT_CCCUSER_PASSWORD ) "
    echo $DEFAULT_CCCUSER_PASSWORD | sudo -Sp "" -u $OWNER sed -i "s/$parameter/$value/g" $file &>> $LOGFILE
    if [[ $? != 0 ]]
    then
      print "ERROR: unable to update $parameter on $file with value $value"
    fi

}

#=========================================================================
#The updateProperties function updates a key on a properties file
#=========================================================================
function updateProperties(){

   key=$1
   value=$2
   file=$3

   print "#### Updating key [$key] with value [$value] on file [$file]"
   sed -i "/^$key.* =/c$key = $value" $file
   if [[ $? != 0 ]]
   then
     print "ERROR: unable to update key $key on $file with value $value"
   fi
}

#=========================================================================
#The downloadRepo function download AEM requirements zip files
#=========================================================================
function downloadRepo(){

    print "Download chef repo archive"
    repoArchive="chefRepoController.zip"
    nameMd5Entry=$(cat $vpsConfFile | grep $repoArchive)
    downloadAndCheckFile "$vpsURL/chef" $BLUEPRINT_DIR $nameMd5Entry

    print "Extract chef repo"
    if [[ ! -f $BLUEPRINT_DIR/$repoArchive ]]
    then
      print "ERROR: unable to find $BLUEPRINT_DIR/$repoArchive. Probably there is an issue on VPS. Contact C3DNA Support"
    fi
    unzip "$BLUEPRINT_DIR/$repoArchive" -d $BLUEPRINT_DIR &>> $LOGFILE
    rm "$BLUEPRINT_DIR/$repoArchive" &>> $LOGFILE

    print "Update cookbooks local repo with downloaded"
    #TODO remove after test with old cookbooks
    rm -r /var/chef/cache/cookbooks/cron

    cp -r $BLUEPRINT_DIR/cookbooks/* /var/chef/cache/cookbooks &>> $LOGFILE

}

#=========================================================================
#The downloadAemRequirements function download AEM requirements zip files
#=========================================================================
function downloadAemRequirements(){

    local mode=$1

    targetDir="$CCC_HOME/plugins/aem-controller-v1/archives/"
    if [[ $mode == "remote" ]]
    then
        nameMd5Entry=$(cat $vpsConfFile | grep "author.zip")
        downloadAndCheckFile $vpsURL $targetDir $nameMd5Entry

        nameMd5Entry=$(cat $vpsConfFile | grep "publish.zip")
        downloadAndCheckFile $vpsURL $targetDir $nameMd5Entry
    else
        cp $BLUEPRINT_DIR/aem/author.zip $targetDir &>> $LOGFILE
        cp $BLUEPRINT_DIR/aem/publish.zip $targetDir &>> $LOGFILE
    fi

    symLinkTarget="$CCC_HOME/Download/aem-publish/615760446/615760446"
    print "Create symbolic link of $publish.zip on $symLinkTarget"
    echo $NEW_CCCUSER_PASSWORD | sudo -Sp "" -u $OWNER mkdir -p $symLinkTarget

    ln -s "$targetDir/publish.zip" "$symLinkTarget/publish.zip"

}

#=========================================================================
#The downloadAndCheckFile function downloads a specific file on a target directory and check its md5
#============================== ==========================================
function downloadAndCheckFile(){

  local url=$1
  local targetDir=$2
  local fileAndMd5=$3

  fileName=$(echo ${fileAndMd5%:*})
  fileMd5=$(echo ${fileAndMd5##*:})

  targetFile=$url/$fileName
  print "Downloading $targetFile on $targetDir"
  wget "$targetFile" -P $targetDir &>> $LOGFILE

  print "Calculating md5 for download file $targetFile"
  calculatedMd5=$(md5sum $targetDir/$fileName | cut -d " " -f1)

  print "Calculated md5 is [$calculatedMd5]. Check if it is equals to [$fileMd5]"
  if [[ $calculatedMd5 == $fileMd5 ]]
  then
    print "File $targetFile downloaded correctly!"
  else
    print "ERROR: some problem has occurred on downloading file $targetFile. Downloaded file is corrupted. Md5 don't correspond. Check network and retry"
  fi

}

#=========================================================================
#The configureParamPlatfomBP function updates platform BP parameters
#============================== ==========================================
function configureParamPlatfomBP(){

  propFile="$CCC_HOME/plugins/CloudController-V2/conf/CloudController.properties"

  updateProperties "ctl.location.default" $locationAlias $propFile
  updateProperties "ctl.group.default" $serverGroup $propFile
  updateProperties "ctl.network.default" $serverNetwork $propFile

  updateProperties "ctl.auth.v1.key" $apiV1Key $propFile
  updateProperties "ctl.auth.v1.pwd" $apiV1Password $propFile
  updateProperties "ctl.auth.v2.key" $apiV2User $propFile
  updateProperties "ctl.auth.v2.pwd" $apiV2Password $propFile

  updateProperties "ctl.runner.repo.url" $platformRepoURL $propFile
  updateProperties "ctl.runner.repo.branch" $platformRepoBranch $propFile
  updateProperties "ctl.runner.repo.playbook" $platformRepoPlaybook $propFile

  updateProperties "ctl.runner.server.password" $serverRootPassword $propFile
  updateProperties "ctl.runner.server.datacenter" $locationAlias $propFile
  updateProperties "ctl.runner.server.group" $serverGroup $propFile

}

#=========================================================================
#The configureController functions goes to configure the controller instance parameters
#============================== ==========================================
function configureController(){

timestamp
print "#######\n Configure Controller \n#######\ninternalIP=$internalIP\ncccuserPassword=$DEFAULT_CCCUSER_PASSWORD\nExecuted by: $USER_NAME\nCurrent Path: $USER_PATH\nTimestamp: $TIMESTAMP\nHome dir Content=\n[\n$CONTENT\n]\n" > $LOGFILE

for i in $(seq 1 5);
do
  timestamp
  print "Attempt n°$i - $TIMESTAMP"
  if [[ -f $CONF_FILE  ]]
  then

      updatePlaceholder "<INTERNAL_IP>" $internalIP $CONF_FILE
      updatePlaceholder "<PUBLIC_IP>" $publicIP $CONF_FILE
      updatePlaceholder "<CCCUSER_PASSWORD>" $NEW_CCCUSER_PASSWORD $CONF_FILE

      FILE_CONTENT=$(cat $CONF_FILE)
      print "\nFile $CONF_FILE content is:\n[\n$FILE_CONTENT\n]\n"

      sudo chef-solo -c $BLUEPRINT_DIR/solo.rb -j $BLUEPRINT_DIR/conf.json &>> $LOGFILE
      tail -n 10 $LOGFILE  | grep "process exited unsuccessfully" &>> /dev/null
      if [[ $? == 0 ]]
      then
         print "ERROR: unable to execute chef-solo configuration"
      fi

      #====
      #NOTE: after this step the 'cccuser' password is equals to $NEW_CCCUSER_PASSWORD
      #====

      # Download AEM Requirements from VPS
      #===================
      downloadAemRequirements "remote"

      # Configure parameters for platform BP execution
      #===================
      configureParamPlatfomBP

      cd $CCC_HOME

      echo $NEW_CCCUSER_PASSWORD | sudo -Sp "" -u $OWNER sudo chown cccuser:ccc -R $CCC_HOME &>> $LOGFILE

      echo $NEW_CCCUSER_PASSWORD | sudo -Sp "" -u $OWNER sudo chmod 775 -R $CCC_HOME &>> $LOGFILE

      echo $NEW_CCCUSER_PASSWORD | sudo -Sp "" -u $OWNER bash $CCC_HOME/engine.sh stop &>> $LOGFILE

      sleep 2

      print "Executing prepare script"
      echo $NEW_CCCUSER_PASSWORD | sudo -Sp "" -u $OWNER bash $CCC_HOME/hard.sh &>> $LOGFILE || print "ERROR unable to prepare controller"

      sleep 1

      print "Executing engine script"
      echo $NEW_CCCUSER_PASSWORD | sudo -Sp "" -u $OWNER bash $CCC_HOME/engine.sh start &>> $LOGFILE || print "ERROR unable to engine controller"

      print "Controller has been configured correctly!"
      exit 0;

  else
    print "File $CONF_FILE not found. Wait 1 minute and retry"
  fi
  sleep 1m
done

print "ERROR: 5 minutes passed. No file found"

}

# Init log file
#===================
initLog

# Restore resolv.conf
#===================
restoreResolvConf

# Get location alias
#===================
getLocationAlias

# Download Chef Repo and Useful Files from VPS
#===================
downloadRepo

# Configure Controller
#===================
configureController
