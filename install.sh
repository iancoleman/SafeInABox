#!/bin/bash

# Prepares a fresh server to be a safe in a box

# Must be run as root
# TODO check current user is root

# Load configuration
. "safe_in_a_box.config"

# Variables - configurable
export SAFE_USERNAME=${SAFE_USERNAME-"safebox"}
export SAFE_PASSWORD=${SAFE_PASSWORD-"password"}
export SAFE_LAUNCHER_VERSION=${SAFE_LAUNCHER_VERSION-"0.8.0"}
export SAFE_DEMO_APP_VERSION=${SAFE_DEMO_APP_VERSION-"0.6.0"}
export SAFE_VAULT_VERSION=${SAFE_VAULT_VERSION-"0.10.5"}
export SAFE_CORE_VERSION=${SAFE_CORE_VERSION-"0.19.0"}
export VAULT_MAX_CAPACITY=${VAULT_MAX_CAPACITY-"104857600"}
export DEFAULT_ACCOUNT_SIZE=${DEFAULT_ACCOUNT_SIZE-"500"}
export FILE_UPLOAD_SIZE_RESTRICTED=${FILE_UPLOAD_SIZE_RESTRICTED-"true"}
export MAX_FILE_UPLOAD_SIZE=${MAX_FILE_UPLOAD_SIZE-"25"}
export NUMBER_OF_VAULTS=${NUMBER_OF_VAULTS-"10"}
export VAULT_PORT=${VAULT_PORT-"5500"}
export NODE_VERSION=${NODE_VERSION-"6.0.0"}
export GROUP_SIZE=${GROUP_SIZE-"8"}
export QUORUM_SIZE=${QUORUM_SIZE-"5"}
export CHECK_ACCOUNT_SIZE_ON_VAULT=${CHECK_ACCOUNT_SIZE_ON_VAULT-"true"}
export RESTRICT_TO_ONE_VAULT_PER_LAN=${RESTRICT_TO_ONE_VAULT_PER_LAN-"false"}

# Variables - nonconfigurable
export START_DIR="/home/$SAFE_USERNAME"
export SAFE_LIBS_DIR="$START_DIR/safe_libs"
export CUSTOMAPPS_DIR="$START_DIR/CustomSafeApps"
export LIBSODIUM_VERSION="1.0.9"
export SODIUM_LIB_DIR="/usr/local/lib"
export NVM_DIR="$START_DIR/.nvm"
export LIBCORE_DST="app/api/ffi/"
export SUBNET2="192.168"
export NETWORK_INTERFACE=`ifconfig | grep -B1 "inet addr:$SUBNET2" | awk '$1!="inet" && $1!="--" {print $1}' | head -n 1`
export MASTER_IP=`ifconfig $NETWORK_INTERFACE | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}'`
export SUBNET3=`echo $MASTER_IP | egrep -o "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"`
export NETWORK_NAME="Private_Safe_Network_`date +%Y_%m_%d_%H_%M_%S`"
export SHARED_DIR=/shared
export VAULTS_DIR="$START_DIR/vaults"
export PORT_PREFIX=500
export FIRST_VAULT_PORT=$PORT_PREFIX\1

main() {

    # set system state
    validate_configuration
    install_updates
    install_dependencies
    create_safebox_user

    # Move to custom apps directory
    su -c "mkdir -p $CUSTOMAPPS_DIR" $SAFE_USERNAME
    cd $CUSTOMAPPS_DIR

    # run commands as root
    install_libsodium
    install_rust
    install_file_sharing

    # run commands as safebox
    su $SAFE_USERNAME -c "bash -c install_node"
    su $SAFE_USERNAME -c "bash -c set_local_safe_libraries"
    su $SAFE_USERNAME -c "bash -c install_safe_core"
    su $SAFE_USERNAME -c "bash -c install_routing"
    su $SAFE_USERNAME -c "bash -c build_safe_core"
    su $SAFE_USERNAME -c "bash -c install_safe_launcher"
    su $SAFE_USERNAME -c "bash -c install_maidsafe_demo_app"
    su $SAFE_USERNAME -c "bash -c install_safe_vault"

    # start the vaults
    su $SAFE_USERNAME -c "bash -c start_network"

    log_info "Finished setting up Safe In A Box as network $NETWORK_NAME"
    log_info "Custom apps are shared as detailed:"
    log_info "samba: look for the SAFE_IN_A_BOX workgroup"
    log_info "nfs: mount $MASTER_IP:$SHARED_DIR /path/to/mount/it"
    log_info "You must copy these custom apps locally for them to work correctly."
}

validate_configuration() {
    # Check number of vaults can produce a valid consensus group
    MIN_VAULTS=$(($GROUP_SIZE + 1))
    if [ "$NUMBER_OF_VAULTS" -lt "$MIN_VAULTS" ]
    then
        log_error "Need at least $MIN_VAULTS vaults, but NUMBER_OF_VAULTS is $NUMBER_OF_VAULTS"
        exit 1
    fi
    # Check number of vaults can fit on subnet
    # Could be 254 but let's keep it round.
    # 256 total addresses, less 1 for gateway, less 1 for master node.
    MAX_VAULTS=250
    if [ "$NUMBER_OF_VAULTS" -gt "$MAX_VAULTS" ]
    then
        log_error "Can support at most $MAX_VAULTS vaults, but NUMBER_OF_VAULTS is $NUMBER_OF_VAULTS"
        exit 1
    fi
    # Check quorum can be reached
    MAX_QUORUM=$((GROUP_SIZE - 1))
    if [ "$QUORUM_SIZE" -gt "$MAX_QUORUM" ]
    then
        log_error "Can support at most $MAX_QUORUM quorum size, but QUORUM_SIZE is $QUORUM_SIZE"
        exit 1
    fi
    MIN_QUORUM=1
    if [ "$QUORUM_SIZE" -lt "$MIN_QUORUM" ]
    then
        log_error "Need at least $MIN_QUORUM quorum size, but QUORUM_SIZE is $QUORUM_SIZE"
        exit 1
    fi
}

# Be up to date if last update more than one day ago
install_updates(){
    SECONDS_SINCE_UPDATE=`expr $(date +%s) - $(date +%s -r /var/cache/apt/pkgcache.bin)`
    if [ $SECONDS_SINCE_UPDATE -gt "86400" ]
    then
        log_info "Installing updates"
        apt-get update
    else
        log_info "Update last happend $SECONDS_SINCE_UPDATE seconds ago, will only update after one day."
    fi
    apt-get upgrade --yes
}

# Install dependencies
install_dependencies(){
    log_info "Installing dependencies"
    apt-get install --yes build-essential rpm git libssl-dev libreadline-dev zlib1g-dev python-software-properties libgtk2.0-0 libnotify-dev libgconf-2-4 libasound2 apt-transport-https ca-certificates
}

# Create unprivileged user
create_safebox_user(){
    if [ -d /home/$SAFE_USERNAME ]
    then
        log_info "$SAFE_USERNAME user already created"
    else
        log_info "Creating user '$SAFE_USERNAME'"
        useradd --create-home $SAFE_USERNAME
        echo "$SAFE_USERNAME:$SAFE_PASSWORD" | chpasswd
    fi
}

# Install file sharing
install_file_sharing(){
    mkdir -p "$SHARED_DIR"
    chmod 777 "$SHARED_DIR"
    install_samba
    install_nfs
}

# Install samba file sharing
install_samba(){
    if hash samba 2>/dev/null
    then
        log_info "samba already installed"
    else
        log_info "Installing samba file sharing"
        apt-get install --yes samba
        cat > /etc/samba/smb.conf <<END
[global]
workgroup = SAFE_IN_A_BOX
server string = %h server (Samba, Ubuntu)
dns proxy = no
log file = /var/log/samba/log.%m
max log size = 1000
syslog = 0
panic action = /usr/share/samba/panic-action %d
server role = standalone server
passdb backend = tdbsam
obey pam restrictions = yes
unix password sync = yes
passwd program = /usr/bin/passwd %u
passwd chat = *Enter\snew\s*\spassword:* %n\n *Retype\snew\s*\spassword:* %n\n *password\supdated\ssuccessfully* .
pam password change = yes
map to guest = bad user
usershare allow guests = yes
[public]
comment = Safe In A Box Apps
path = $SHARED_DIR
read only = no
guest only = yes
guest ok = yes
END
        service smbd restart
    fi
}

# Install nfs file sharing
install_nfs(){
    if [ "`dpkg -la | grep nfs-kernel-server | wc -l`" -gt "0" ]
    then
        log_info "nfs-kernel-server already installed"
    else
        log_info "Installing nfs-kernel-server file sharing"
        apt-get install --yes nfs-kernel-server
        cat > /etc/exports <<END
$SHARED_DIR 192.168.*.*(rw,sync,no_subtree_check,insecure)
END
        service nfs-kernel-server restart
    fi
}

# Install libsodium
install_libsodium(){
    cd $CUSTOMAPPS_DIR
    if [ ! -d libsodium-$LIBSODIUM_VERSION ]
    then
        log_info "Installing libsodium"
        su $SAFE_USERNAME << RUNASUSER
cd $CUSTOMAPPS_DIR
wget https://github.com/jedisct1/libsodium/releases/download/$LIBSODIUM_VERSION/libsodium-$LIBSODIUM_VERSION.tar.gz
tar xfz libsodium-$LIBSODIUM_VERSION.tar.gz
rm libsodium-$LIBSODIUM_VERSION.tar.gz
cd libsodium-$LIBSODIUM_VERSION
./configure --enable-shared=no --disable-pie
make check
RUNASUSER
        cd $CUSTOMAPPS_DIR/libsodium-$LIBSODIUM_VERSION
        make install
    else
        log_info "libsodium already installed"
    fi
}

# Install rust
# see https://doc.rust-lang.org/book/getting-started.html#installing-on-linux-or-mac
install_rust(){
    cd $CUSTOMAPPS_DIR
    if hash rustc 2>/dev/null
    then
        log_info "rust already installed"
    else
        log_info "Installing rust"
        curl -sSf https://static.rust-lang.org/rustup.sh | sh
    fi
}
export -f install_rust

start_network(){
    # Stop all vaults
    log_info "Stopping all existing vaults"
    pkill safe_vault
    # Remove old vaults
    log_info "Removing all existing vaults"
    rm -r $VAULTS_DIR/*
    # Create new vaults
    for i in $(seq 1 1 $NUMBER_OF_VAULTS)
    do
        log_info "Creating and starting vault $i"
        VAULT_DIR=$VAULTS_DIR/vault_$i
        mkdir -p $VAULT_DIR

        # safe_vault
        cp $CUSTOMAPPS_DIR/safe_vault/target/release/safe_vault $VAULT_DIR

        # safe_vault.crust.config
        VAULT_CRUST_CONFIGFILE=$VAULT_DIR/safe_vault.crust.config
        THIS_VAULT_PORT=$PORT_PREFIX$i
        cat > $VAULT_CRUST_CONFIGFILE <<END
{
  "hard_coded_contacts": [
END
        for PORT_INDEX in $(seq 1 1 $NUMBER_OF_VAULTS)
        do
            PORT=$PORT_PREFIX$PORT_INDEX
            if [ $PORT_INDEX -eq $NUMBER_OF_VAULTS ]
            then
                echo "    \"$MASTER_IP:$PORT\"" >> "$VAULT_CRUST_CONFIGFILE"
            else
                echo "    \"$MASTER_IP:$PORT\"," >> "$VAULT_CRUST_CONFIGFILE"
            fi
        done
        cat >> "$VAULT_CRUST_CONFIGFILE" <<END
  ],
  "tcp_acceptor_port": "$THIS_VAULT_PORT",
  "service_discovery_port": "$FIRST_VAULT_PORT",
  "bootstrap_cache_name": null,
  "network_name": "$NETWORK_NAME"
}
END

        # safe_vault.vault.config
        cat > $VAULT_DIR/safe_vault.vault.config <<END
{
  "wallet_address": null,
  "max_capacity": $VAULT_MAX_CAPACITY,
  "chunk_store_root": "$VAULT_DIR"
}
END

        # log.toml
        cat > $VAULT_DIR/log.toml <<END
[appender.async_console]
kind = "async_console"
pattern = "%l %d{%H:%M:%S.%f} [%M #FS#%f#FE#:%L] %m"

[[appender.async_console.filter]]
kind = "threshold"
level = "info"

[appender.async_file]
kind = "async_file"
path = "Node.log"
pattern = "%l %d{%H:%M:%S.%f} [%M #FS#%f#FE#:%L] %m"
append = false

[root]
level = "error"
appenders = ["async_console", "async_file"]

[[logger]]
name = "crust"
level = "debug"
appenders = ["async_file"]
additive = false

[[logger]]
name = "routing"
level = "debug"

[[logger]]
name = "safe_vault"
level = "debug"
END

        # Start the vault
        cd $VAULT_DIR
        if [ $i -eq "1" ]
        then
            nohup ./safe_vault --first >> vault.log &
        else
            nohup ./safe_vault >> vault.log &
        fi
        sleep 3
    done
}
export -f start_network

# Install nodejs using nvm
# see https://github.com/creationix/nvm#installation
install_node(){
    cd $CUSTOMAPPS_DIR
    # install nvm
    if [ ! -d $START_DIR/.nvm ]
    then
        log_info "Installing nvm"
        wget -O "$START_DIR/install_nvm.sh" https://raw.githubusercontent.com/creationix/nvm/v0.31.1/install.sh
        export HOME=$START_DIR
        export PROFILE=$START_DIR/.bashrc
        /bin/sh "$START_DIR/install_nvm.sh"
        rm "$START_DIR/install_nvm.sh"
    else
        log_info "nvm already installed"
    fi
    # install node
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"  # This loads nvm
    if [ ! -d $NVM_DIR/versions/node/v$NODE_VERSION ]
    then
        log_info "Installing nodejs v$NODE_VERSION"
        nvm install $NODE_VERSION
    else
        log_info "nodejs v$NODE_VERSION already installed"
    fi
    nvm use $NODE_VERSION
}
export -f install_node

# Install Safe Core (required for launcher)
install_safe_core(){
    cd $SAFE_LIBS_DIR
    if [ ! -d safe_core ]
    then
        log_info "Installing safe_core"
        git clone https://github.com/maidsafe/safe_core.git
    else
        log_info "safe_core already installed"
    fi
    cd safe_core
    # Checkout correct version if required
    CURRENT_VERSION=`git status | head -1 | awk '{print $4}'`
    if [ "$CURRENT_VERSION" != "$SAFE_CORE_VERSION" ]
    then
        log_info "Checking out version $SAFE_CORE_VERSION of safe_core, currently at $CURRENT_VERSION"
        git pull
        rm Cargo.lock
        git checkout -- .
        git checkout $SAFE_CORE_VERSION
    else
        log_info "Already using version $SAFE_CORE_VERSION of safe_core"
    fi
}
export -f install_safe_core

# Build safe core (required for launcher)
build_safe_core(){
    cd $SAFE_LIBS_DIR/safe_core
    # Build if required
    BUILD_TIME_FILE='.last_automated_build_time'
    if [ ! -f $BUILD_TIME_FILE ]
    then
        touch -t 7001010000 $BUILD_TIME_FILE
    fi
    if [ ! -f $BUILD_TIME_FILE ]
    then
        touch -t 7001010000 $BUILD_TIME_FILE
    fi
    if [ "`find ./* -cnewer $BUILD_TIME_FILE | wc -l`" -gt "0" ]
    then
        log_info "Building safe_core"
        cargo build --release
        touch $BUILD_TIME_FILE
        # must rebuild launcher with new safe_core
        if [ -d $CUSTOMAPPS_DIR/safe_launcher ]
        then
            touch $CUSTOMAPPS_DIR/safe_launcher/force_rebuild
        fi
    else
        log_info "Safe Core has had no changes since last automated build"
    fi
}
export -f build_safe_core

# Install Routing (required for custom group sizes)
install_routing(){
    cd $SAFE_LIBS_DIR
    if [ ! -d routing ]
    then
        log_info "Installing routing"
        git clone https://github.com/maidsafe/routing.git
    else
        log_info "routing already installed"
    fi
}
export -f install_routing

# Install and build Safe Launcher
install_safe_launcher(){
    cd $CUSTOMAPPS_DIR
    if [ ! -d safe_launcher ]
    then
        log_info "Installing safe_launcher"
        git clone https://github.com/maidsafe/safe_launcher.git
    else
        log_info "safe_launcher already installed"
    fi
    cd safe_launcher
    # Checkout correct version if required
    CURRENT_VERSION=`git status | head -1 | awk '{print $4}'`
    if [ "$CURRENT_VERSION" != "$SAFE_LAUNCHER_VERSION" ]
    then
        log_info "Checking out version $SAFE_LAUNCHER_VERSION of safe_launcher, currently at $CURRENT_VERSION"
        git pull
        git checkout -- .
        git checkout $SAFE_LAUNCHER_VERSION
    else
        log_info "Already using version $SAFE_LAUNCHER_VERSION of safe_launcher"
    fi
    # Build if required
    BUILD_TIME_FILE='.last_automated_build_time'
    if [ ! -f $BUILD_TIME_FILE ]
    then
        touch -t 7001010000 $BUILD_TIME_FILE
    fi
    if [ "`find ./* -cnewer $BUILD_TIME_FILE | grep -v app_dist | wc -l`" -gt "0" ]
    then
        log_info "Building safe_launcher"
        # load nvm
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        # copy libsafe_core.so to ffi directory
        # see https://github.com/maidsafe/safe_launcher/blob/abacc902bba4c1b805e541f17d16af7066a98e5d/README.md#quick-start
        mkdir -p $LIBCORE_DST
        cp $SAFE_LIBS_DIR/safe_core/target/release/libsafe_core.so $LIBCORE_DST
        # install dependencies
        npm install
        # remove old version
        if [ -d app_dist ]
        then
            rm -r app_dist/*
        fi
        # build the new package
        npm run package
        touch $BUILD_TIME_FILE
    else
        log_info "Launcher has not changed since last build"
    fi
    # create config
    LAUNCHER_ROOT=$CUSTOMAPPS_DIR/safe_launcher/app_dist
    APP_DIR=$LAUNCHER_ROOT/`ls $LAUNCHER_ROOT | sort | tail -n 1`
    SAFE_LAUNCHER_CONFIGFILE="$APP_DIR/safe_launcher.crust.config"
    cat > "$SAFE_LAUNCHER_CONFIGFILE" <<END
{
  "hard_coded_contacts": [
END
    for PORT_INDEX in $(seq 1 1 $NUMBER_OF_VAULTS)
    do
        PORT=$PORT_PREFIX$PORT_INDEX
        if [ $PORT_INDEX -eq $NUMBER_OF_VAULTS ]
        then
            echo "    \"$MASTER_IP:$PORT\"" >> "$SAFE_LAUNCHER_CONFIGFILE"
        else
            echo "    \"$MASTER_IP:$PORT\"," >> "$SAFE_LAUNCHER_CONFIGFILE"
        fi
    done
    cat >> "$SAFE_LAUNCHER_CONFIGFILE" <<END
  ],
  "tcp_acceptor_port": null,
  "service_discovery_port": "$FIRST_VAULT_PORT",
  "bootstrap_cache_name": null,
  "network_name": "$NETWORK_NAME"
}
END
    # Copy new release to the share
    rm -r $SHARED_DIR/*safe_launcher*
    cp -r $CUSTOMAPPS_DIR/safe_launcher/app_dist/* $SHARED_DIR
}
export -f install_safe_launcher

# Install and build MaidSafe DemoApp
install_maidsafe_demo_app(){
    cd $CUSTOMAPPS_DIR
    if [ ! -d safe_examples ]
    then
        log_info "Installing maidsafe demoapp"
        git clone https://github.com/maidsafe/safe_examples.git
    else
        log_info "maidsafe demoapp already installed"
    fi
    cd safe_examples/demo_app
    # Checkout correct version if required
    CURRENT_VERSION=`git status | head -1 | awk '{print $4}'`
    if [ "$CURRENT_VERSION" != "$SAFE_DEMO_APP_VERSION" ]
    then
        log_info "Checking out version $SAFE_DEMO_APP_VERSION of maidsafe demo app, currently at $CURRENT_VERSION"
        git pull
        git checkout -- .
        git checkout $SAFE_DEMO_APP_VERSION
    else
        log_info "Already using version $SAFE_DEMO_APP_VERSION of maidsafe demo app"
    fi
    # Make changes
    # set isFileUploadSizeRestricted
    OLD="isFileUploadSizeRestricted\": .\+,"
    NEW="isFileUploadSizeRestricted\": $FILE_UPLOAD_SIZE_RESTRICTED,"
    if [ "`grep -r "$NEW" ./config | wc -l`" -eq "0" ]
    then
        log_info "Changing demo_app isFileUploadSizeRestricted to $FILE_UPLOAD_SIZE_RESTRICTED"
        sed -i s/"$OLD"/"$NEW"/g config/*
        touch config/*
    else
        log_info "demo_app isFileUploadSizeRestricted is already set to $FILE_UPLOAD_SIZE_RESTRICTED"
    fi
    # set maxFileUploadSize
    OLD="maxFileUploadSize\": [0-9]\+"
    NEW="maxFileUploadSize\": $MAX_FILE_UPLOAD_SIZE"
    if [ "`grep -r "$NEW" ./config | wc -l`" -eq "0" ]
    then
        log_info "Changing demo_app maxFileUploadSize to $MAX_FILE_UPLOAD_SIZE"
        sed -i s/"$OLD"/"$NEW"/g config/*
        touch config/*
    else
        log_info "demo_app maxFileUploadSize is already set to $MAX_FILE_UPLOAD_SIZE"
    fi
    # Build if changed
    BUILD_TIME_FILE='.last_automated_build_time'
    if [ ! -f $BUILD_TIME_FILE ]
    then
        touch -t 7001010000 $BUILD_TIME_FILE
    fi
    if [ "`find ./* -cnewer $BUILD_TIME_FILE | wc -l`" -gt "0" ]
    then
        log_info "Building maidsafe demoapp"
        # This loads nvm
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        # Install dependencies
        npm install
        if [ -d app_dist ]
        then
            rm -r app_dist/*
        fi
        # Create new demoapp with changes
        npm run package
        touch $BUILD_TIME_FILE
    else
        log_info "Demo App has not changed since last build"
    fi
    # Copy new release to the share
    rm -r $SHARED_DIR/*demo*app*
    cp -r $CUSTOMAPPS_DIR/safe_examples/demo_app/app_dist/* $SHARED_DIR
}
export -f install_maidsafe_demo_app

# Install and build Safe Vault
install_safe_vault(){
    cd $CUSTOMAPPS_DIR
    if [ ! -d safe_vault ]
    then
        log_info "Installing safe_vault"
        git clone https://github.com/maidsafe/safe_vault.git
    else
        log_info "safe_vault already installed"
    fi
    cd safe_vault
    # Checkout correct version if required
    CURRENT_VERSION=`git status | head -1 | awk '{print $4}'`
    if [ "$CURRENT_VERSION" != "$SAFE_VAULT_VERSION" ]
    then
        log_info "Checkout out version $SAFE_VAULT_VERSION of safe_vault, currently at $CURRENT_VERSION"
        git pull
        rm Cargo.lock
        git checkout -- .
        git checkout $SAFE_VAULT_VERSION
    else
        log_info "Already using version $SAFE_VAULT_VERSION of safe_vault"
    fi
    # Make changes
    # change max_capacity
    OLD="max_capacity\": .\+"
    NEW="max_capacity\": $VAULT_MAX_CAPACITY"
    if [ "`grep -r "$NEW" ./installer/common | wc -l`" -eq "0" ]
    then
    log_info "Changing safe_vault max_capacity to $VAULT_MAX_CAPACITY"
    sed -i s/"$OLD"/"$NEW"/g ./installer/common/sample.vault.config
    touch ./installer/common/sample.vault.config
    else
    log_info "safe_vault max_capacity is already set to $VAULT_MAX_CAPACITY"
    fi
    # change default_account_size
    OLD="DEFAULT_ACCOUNT_SIZE: u64 = .\+;"
    NEW="DEFAULT_ACCOUNT_SIZE: u64 = $DEFAULT_ACCOUNT_SIZE;"
    if [ "`grep -r "$NEW" ./src | wc -l`" -eq "0" ]
    then
        log_info "Changing safe_vault DEFAULT_ACCOUNT_SIZE to $DEFAULT_ACCOUNT_SIZE"
        sed -i s/"$OLD"/"$NEW"/g ./src/personas/maid_manager.rs
        touch ./src/personas/maid_manager.rs
    else
        log_info "safe_vault DEFAULT_ACCOUNT_SIZE is already set to $DEFAULT_ACCOUNT_SIZE"
    fi
    # set check for space_available on accounts
    if [ "$CHECK_ACCOUNT_SIZE_ON_VAULT" = "false" ]
    then
        # disable check for space_available
        OLD=" return Err(MutationError::LowBalance);"
        NEW=" //return Err(MutationError::LowBalance);"
    else
        # enable check for space_available
        OLD=" //return Err(MutationError::LowBalance);"
        NEW=" return Err(MutationError::LowBalance);"
    fi
    if [ "`grep -r "$NEW" ./src | wc -l`" -eq "0" ]
    then
        log_info "Changing safe_vault check for space_available to $CHECK_ACCOUNT_SIZE_ON_VAULT"
        OLD_SED=${OLD//\//\\\/} # escape forward slashes
        NEW_SED=${NEW//\//\\\/} # escape forward slashes
        sed -i s/"$OLD_SED"/"$NEW_SED"/g ./src/personas/maid_manager.rs
        touch ./src/personas/maid_manager.rs
    else
        log_info "safe_vault check for space_available is already set to $CHECK_ACCOUNT_SIZE_ON_VAULT"
    fi
    # change to use local routing
    OLD=`grep "^routing = "  Cargo.toml`
    ROUTING_VERSION=`echo $OLD | egrep -o "\"[0-9\.\~]+\""`
    ROUTING_VERSION_CLEAN=`echo $ROUTING_VERSION | tr -d \"~`
    NEW="routing = { path = \"$SAFE_LIBS_DIR/routing\", version = $ROUTING_VERSION }"
    if [ "`grep -r "$NEW" ./Cargo.toml | wc -l`" -eq "0" ]
    then
        log_info "Changing safe_vault routing to use local version"
        NEW_SED=${NEW//\"/\\\"} # escape double quotes
        NEW_SED=${NEW_SED//\//\\\/} # escape forward slashes
        sed -i s/"$OLD"/"$NEW_SED"/g ./Cargo.toml
        touch ./Cargo.toml
    else
        log_info "safe_vault routing is already set to use local version"
    fi
    # Ensure routing is at correct version
    cd $SAFE_LIBS_DIR/routing
    CURRENT_VERSION=`git status | head -1 | awk '{print $4}'`
    if [ "$CURRENT_VERSION" != "$ROUTING_VERSION_CLEAN" ]
    then
        log_info "Checkout version $ROUTING_VERSION_CLEAN of routing, currently at $CURRENT_VERSION"
        git pull
        rm Cargo.lock
        git checkout -- .
        git checkout $ROUTING_VERSION_CLEAN
    else
        log_info "Routing is already at $ROUTING_VERSION_CLEAN"
    fi
    # Change routing group size if required
    # TODO this substitution is fragile, especially around filename
    OLD="pub const GROUP_SIZE: usize = .\+"
    NEW="pub const GROUP_SIZE: usize = $GROUP_SIZE;"
    if [ "`grep -r "$NEW" ./src | wc -l`" -eq "0" ]
    then
        log_info "Changing routing GROUP_SIZE to $GROUP_SIZE"
        sed -i s/"$OLD"/"$NEW"/g ./src/peer_manager.rs
        touch ./src/peer_manager.rs
        # Force safe_vault to be rebuilt
        touch $CUSTOMAPPS_DIR/safe_vault/force_rebuild
    else
        log_info "routing GROUP_SIZE is already set to $GROUP_SIZE"
    fi
    # Change routing quorum size if required
    OLD="pub const QUORUM_SIZE: usize = .\+"
    NEW="pub const QUORUM_SIZE: usize = $QUORUM_SIZE;"
    if [ "`grep -r "$NEW" ./src | wc -l`" -eq "0" ]
    then
        log_info "Changing routing QUORUM_SIZE to $QUORUM_SIZE"
        sed -i s/"$OLD"/"$NEW"/g ./src/peer_manager.rs
        touch ./src/peer_manager.rs
        # Force safe_vault to be rebuilt
        touch $CUSTOMAPPS_DIR/safe_vault/force_rebuild
    else
        log_info "routing QUORUM_SIZE is already set to $QUORUM_SIZE"
    fi
    # Change routing check for one vault on lan if required
    # TODO this substitution is very fragile...
    if [ "$RESTRICT_TO_ONE_VAULT_PER_LAN" = "false" ]
    then
        # disable check for deny_other_local_nodes
        OLD="deny_other_local_nodes \&\& crust_service.has_peers_on_lan()"
        NEW="deny_other_local_nodes \&\& false"
    else
        # enable check for deny_other_local_nodes
        OLD="deny_other_local_nodes \&\& false"
        NEW="deny_other_local_nodes \&\& crust_service.has_peers_on_lan()"
    fi
    if [ "`grep -r "$NEW" ./src | wc -l`" -eq "0" ]
    then
        log_info "Changing routing deny_other_local_nodes to $RESTRICT_TO_ONE_VAULT_PER_LAN"
        sed -i s/"$OLD"/"$NEW"/g ./src/node.rs
        touch ./src/node.rs
        # Force safe_vault to be rebuilt
        touch $CUSTOMAPPS_DIR/safe_vault/force_rebuild
    else
        log_info "routing deny_other_local_nodes is already set to $RESTRICT_TO_ONE_VAULT_PER_LAN"
    fi
    # Return to vault
    cd $CUSTOMAPPS_DIR/safe_vault
    # Build custom version of safe_vault
    BUILD_TIME_FILE='.last_automated_build_time'
    if [ ! -f $BUILD_TIME_FILE ]
    then
        touch -t 7001010000 $BUILD_TIME_FILE
    fi
    if [ "`find ./* -cnewer $BUILD_TIME_FILE | wc -l`" -gt "0" ]
    then
        # Create new safe_vault with changes
        log_info "Building safe_vault"
        cargo build --release
        touch $BUILD_TIME_FILE
    else
        log_info "Safe Vault has not changed since last build"
    fi
}
export -f install_safe_vault

set_local_safe_libraries(){
    # Configures safe to use local safe libraries, in particular:
    # safe_core
    # routing
    cd $START_DIR
    mkdir -p $SAFE_LIBS_DIR
}
export -f set_local_safe_libraries

# Logging
log_info(){
    echo -e "\e[1m\e[34mINFO:\e[21m\e[0m $1"
}
export -f log_info

log_error(){
    echo -e "\e[1m\e[31mERROR:\e[21m\e[0m $1"
}
export -f log_info

main
