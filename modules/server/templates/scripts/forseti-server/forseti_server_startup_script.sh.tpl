#!/bin/bash

# function as pulled out of the install
function initialize_forseti_services() {
    # Reference all required bash variables prior to running. Due to 'nounset', if
    # a caller fails to export the following expected environmental variables, this
    # script will fail immediately rather than partially succeeding.
    echo "Cloud SQL Instance Connection string: $${SQL_INSTANCE_CONN_STRING}"
    echo "SQL port: $${SQL_PORT}"
    echo "Forseti DB name: $${FORSETI_DB_NAME}"

    if ! [[ -f $FORSETI_SERVER_CONF ]]; then
        echo "Could not find the configuration file: $${FORSETI_SERVER_CONF}." >&2
        exit 1
    fi

    # We had issue creating DB user through deployment template, if the issue is
    # resolved in the future, we should create a forseti db user instead of using
    # root.
    # https://github.com/GoogleCloudPlatform/forseti-security/issues/921
    SQL_SERVER_LOCAL_ADDRESS="mysql://root@127.0.0.1:$${SQL_PORT}"
    FORSETI_SERVICES="explain inventory model scanner notifier"

    FORSETI_COMMAND="$(which forseti_server) --endpoint '[::]:50051'"
    FORSETI_COMMAND+=" --forseti_db $${SQL_SERVER_LOCAL_ADDRESS}/$${FORSETI_DB_NAME}?charset=utf8"
    FORSETI_COMMAND+=" --config_file_path $${FORSETI_SERVER_CONF}"
    FORSETI_COMMAND+=" --services $${FORSETI_SERVICES}"

    SQL_PROXY_COMMAND="$(which cloud_sql_proxy)"
    SQL_PROXY_COMMAND+=" -instances=$${SQL_INSTANCE_CONN_STRING}=tcp:$${SQL_PORT}"

    # Cannot use "read -d" since it returns a nonzero exit status.
    API_SERVICE="$(
        cat <<EOF
[Unit]
Description=Forseti API Server
Wants=cloudsqlproxy.service
[Service]
User=$USER
Restart=always
RestartSec=3
ExecStart=$FORSETI_COMMAND
[Install]
WantedBy=multi-user.target
EOF
    )"
    echo "$API_SERVICE" >/tmp/forseti.service
    sudo mv /tmp/forseti.service /lib/systemd/system/forseti.service

    # By default, Systemd starts the executable stated in ExecStart= as root.
    # See github issue #1761 for why this neds to be run as root.
    SQL_PROXY_SERVICE="$(
        cat <<EOF
[Unit]
Description=Cloud SQL Proxy
[Service]
Restart=always
RestartSec=3
ExecStart=$SQL_PROXY_COMMAND
[Install]
WantedBy=forseti.service
EOF
    )"
    echo "$SQL_PROXY_SERVICE" >/tmp/cloudsqlproxy.service
    sudo mv /tmp/cloudsqlproxy.service /lib/systemd/system/cloudsqlproxy.service

    # Define a foreground runner. This runner will start the CloudSQL
    # proxy and block on the Forseti API server.
    FOREGROUND_RUNNER="$(
        cat <<EOF
$SQL_PROXY_COMMAND &&
$FORSETI_COMMAND
EOF
    )"
    systemctl daemon-reload
    echo "$FOREGROUND_RUNNER" >/tmp/forseti-foreground.sh
    chmod 755 /tmp/forseti-foreground.sh
    sudo mv /tmp/forseti-foreground.sh /usr/bin/forseti-foreground.sh

    echo "Forseti services are now registered with systemd. Services can be started"
    echo "immediately by running the following:"
    echo ""
    echo "    systemctl start cloudsqlproxy"
    echo "    systemctl start forseti"
    echo ""
    echo "Additionally, the Forseti server can be run in the foreground by using"
    echo "the foreground runner script: /usr/bin/forseti-foreground.sh"
}

# Env variables
USER=ubuntu
USER_HOME=/home/ubuntu

# forseti_conf_server digest: ${forseti_conf_server_checksum}
# This digest is included in the startup script to rebuild the Forseti server VM
# whenever the server configuration changes.

# Ubuntu update.
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
sudo apt-get update -y
sudo apt-get --assume-yes install google-cloud-sdk git unzip

# Install fluentd if necessary.
FLUENTD=$(ls /usr/sbin/google-fluentd)
if [ -z "$FLUENTD" ]; then
    cd $USER_HOME
    curl -sSO https://dl.google.com/cloudagents/install-logging-agent.sh
    bash install-logging-agent.sh
fi

# Check whether Cloud SQL proxy is installed.
CLOUD_SQL_PROXY=$(which cloud_sql_proxy)
if [ -z "$CLOUD_SQL_PROXY" ]; then
    cd $USER_HOME
    wget https://dl.google.com/cloudsql/cloud_sql_proxy.${cloudsql_proxy_arch}
    sudo mv cloud_sql_proxy.${cloudsql_proxy_arch} /usr/local/bin/cloud_sql_proxy
    chmod +x /usr/local/bin/cloud_sql_proxy
fi

# Install Forseti Security.
cd $USER_HOME
rm -rf *forseti*

# Download Forseti source code
git clone ${forseti_repo_url}
cd forseti-security
git fetch --all
git checkout ${forseti_version}

# Forseti host dependencies
sudo apt-get install -y $(cat install/dependencies/apt_packages.txt | grep -v "#" | xargs)

# Forseti dependencies
pip install --upgrade pip==9.0.3
pip install -q --upgrade setuptools wheel
pip install -q --upgrade -r requirements.txt

# Setup Forseti logging
touch /var/log/forseti.log
chown $USER:root /var/log/forseti.log
cp ${forseti_home}/configs/logging/fluentd/forseti.conf /etc/google-fluentd/config.d/forseti.conf
cp ${forseti_home}/configs/logging/logrotate/forseti /etc/logrotate.d/forseti
chmod 644 /etc/logrotate.d/forseti
service google-fluentd restart
logrotate /etc/logrotate.conf

# Change the access level of configs/ rules/ and run_forseti.sh
chmod -R ug+rwx ${forseti_home}/configs ${forseti_home}/rules ${forseti_home}/install/gcp/scripts/run_forseti.sh

# Install tracing libraries
pip install .[tracing]

# Install Forseti
python setup.py install

# Export variables required by initialize_forseti_services.sh.
${forseti_env}

# Export variables required by run_forseti.sh
${forseti_environment}

# Store the variables in /etc/profile.d/forseti_environment.sh
# so all the users will have access to them
echo "${forseti_environment}" >/etc/profile.d/forseti_environment.sh | sudo sh

# Download server configuration from GCS
gsutil cp gs://${storage_bucket_name}/configs/forseti_conf_server.yaml ${forseti_server_conf_path}
gsutil cp -r gs://${storage_bucket_name}/rules ${forseti_home}/

# Start Forseti service depends on vars defined above.
initialize_forseti_services
echo "Starting services."
systemctl start cloudsqlproxy
sleep 5
systemctl start forseti
echo "Success! The Forseti API server has been started."

# Create a Forseti env script
FORSETI_ENV="$(
    cat <<EOF
#!/bin/bash

export PATH=$PATH:/usr/local/bin

# Forseti environment variables
${forseti_environment}
EOF
)"
echo "$FORSETI_ENV" >$USER_HOME/forseti_env.sh

# Use flock to prevent rerun of the same cron job when the previous job is still running.
# If the lock file does not exist under the tmp directory, it will create the file and put a lock on top of the file.
# When the previous cron job is not finished and the new one is trying to run, it will attempt to acquire the lock
# to the lock file and fail because the file is already locked by the previous process.
# The -n flag in flock will fail the process right away when the process is not able to acquire the lock so we won't
# queue up the jobs.
# If the cron job failed the acquire lock on the process, it will log a warning message to syslog.
(echo "${forseti_run_frequency} (/usr/bin/flock -n ${forseti_home}/forseti_cron_runner.lock ${forseti_home}/install/gcp/scripts/run_forseti.sh -b ${storage_bucket_name} || echo '[forseti-security] Warning: New Forseti cron job will not be started, because previous Forseti job is still running.') 2>&1 | logger") | crontab -u $USER -
echo "Added the run_forseti.sh to crontab under user $USER"

if [ -f ${forseti_home}/forseti_cron_runner.lock ]; then
    echo "removed stale lock file"
    rm ${forseti_home}/forseti_cron_runner.lock
fi
chown -R $USER: $USER_HOME

echo "Execution of startup script finished"
