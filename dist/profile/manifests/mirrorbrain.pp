#
# Configure the mirrorbrain service
class profile::mirrorbrain (
  $pg_host      = 'localhost',
  $pg_database  = 'mirrorbrain',
  $pg_username  = 'mirrorbrain',
  $pg_password  = 'mirrorbrain',
  $manage_pgsql = true, # Install and manage PostgreSQL on this node
  $user         = 'mirrorbrain',
  $group        = 'mirrorbrain',
  $groups       = ['www-data'],
  $home_dir     = '/srv/releases',
  $docroot      = '/srv/releases/jenkins',
  $ssh_keys     = undef,
) {
  include ::mirrorbrain
  include ::mirrorbrain::apache

  # Need to declare the 'ruby' class ahead of profile::apachemisc which
  # includes the apachelogcompressor module, which itself does a
  # `contain 'ruby'`
  class { '::ruby' :
    ruby_package => 'ruby2.0',
  }
  # Required for installing the azure-storage gem
  class { '::ruby::dev' :
    ruby_dev_packages => ['ruby2.0-dev'],
  }

  include profile::apachemisc
  include profile::firewall
  include profile::letsencrypt

  $server_name = 'mirrors.jenkins.io'
  $apache_log_dir = "/var/log/apache2/${server_name}"
  $mirrorbrain_conf = '/etc/mirrorbrain.conf'
  $mirmon_conf = '/etc/mirmon.conf'

  File {
    ensure => present,
  }

  group { $group:
    ensure => present,
  }

  # We use the mirrorbrain user for interactive things like rsyncing for
  # completing releases and updating the updates site
  account { $user:
    manage_home    => true,
    # Ensure that our homedir is world-readable, since it's full of public
    # files :)
    home_dir_perms => '0755',
    create_group   => false,
    home_dir       => $home_dir,
    gid            => $group,
    groups         => $groups,
    ssh_keys       => $ssh_keys,
    require        => Group[$group],
  }

  ::ssh::client::config::user { $user :
    ensure              => present,
    user_home_dir       => $home_dir,
    manage_user_ssh_dir => false,
    options             => {
        'Host ftp-osl.osuosl.org'      => {
            'IdentityFile' => "${home_dir}/.ssh/osuosl_mirror",
        },
        'Host archives.jenkins-ci.org' => {
            'IdentityFile' => "${home_dir}/.ssh/archives",
        },
        'Host fallback.jenkins-ci.org' => {
            'IdentityFile' => "${home_dir}/.ssh/archives",
        },
    },
  }

  file { 'osuosl_mirror':
    path    => "${home_dir}/.ssh/osuosl_mirror",
    owner   => $user,
    group   => $group,
    mode    => '0600',
    content => hiera('osuosl_mirroring_privkey'),
    require => Account[$user],
  }

  file { $docroot:
    ensure => directory,
    owner  => $user,
    group  => $group,
  }


  ## Files for Azure blob storage sync
  ##########################
  ensure_packages(['python-pip'])

  # NOTE: The `ruby2.0` package is critically broken/stupid on Ubuntu 14.04, so
  # until we upgrade we will need to manually install and manage the
  # azure-storage gem. See this thread for more details:
  # <https://bugs.launchpad.net/ubuntu/+source/ruby2.0/+bug/1310292>
  #package { 'azure-storage' :
  #  ensure          => present,
  #  # As of 20161107, the gem is in 'beta' so we need --pre to install it from
  #  # rubygems.org
  #  install_options => ['--pre'],
  #  provider        => gem,
  #  require         => Package['ruby'],
  #}
  exec { 'install-azure-storage-gem':
    command => '/usr/bin/gem2.0 install -N --pre azure-storage',
    require => Package['ruby'],
    unless  => '/usr/bin/gem2.0 list | /bin/grep "azure-storage"',
  }

  $azure_account_name = lookup('azure::releases::account_name')
  $azure_access_key   = lookup('azure::releases::access_key')

  file { "${home_dir}/.azure-storage-env":
    ensure  => present,
    content => "
export AZURE_STORAGE_ACCOUNT=${azure_account_name}
export AZURE_STORAGE_KEY=${azure_access_key}",
    owner   => $user,
  }

  apt::source { 'azure-cli':
    location => 'https://apt-mo.trafficmanager.net/repos/azure-cli/',
    release  => 'wheezy',
    repos    => 'main',
    key      => {
      server => 'apt-mo.trafficmanager.net',
      id     => '417A0893',
    },
  }

  package { 'azure-cli':
    ensure  => present,
    require => Apt::Source['azure-cli'],
  }

  file { "${home_dir}/azure-sync.sh" :
    ensure  => present,
    content => "#!/bin/sh

eval `cat ${home_dir}/.azure-storage-env`
wget -O release-blob-sync https://raw.githubusercontent.com/jenkins-infra/azure/master/scripts/release-blob-sync
/usr/bin/ruby2.0 release-blob-sync | sh
",
    owner   => $user,
    mode    => '0755',
    require => [
        Package['azure-cli'],
        Exec['install-azure-storage-gem'],
        File["${home_dir}/.azure-storage-env"],
    ],
  }

  package { 'azure-cli-python' :
    ensure   => absent,
    name     => 'azure-cli',
    provider => pip,
    require  => Package['python-pip'],
  }
  ##########################

  ## Files needed to release
  ##########################
  ## These files are necessary to create and sync releases to and from this host
  ##########################
  file { "${home_dir}/rsync.filter":
    owner  => $user,
    group  => $group,
    source => "puppet:///modules/${module_name}/mirrorbrain/rsync.filter",
  }

  file { "${home_dir}/sync.sh":
    owner  => $user,
    group  => $group,
    source => "puppet:///modules/${module_name}/mirrorbrain/sync.sh",
  }

  file { "${home_dir}/populate-archives.sh":
    owner  => $user,
    group  => $group,
    source => "puppet:///modules/${module_name}/mirrorbrain/populate-archives.sh",
  }

  file { "${home_dir}/populate-fallback.sh":
    owner  => $user,
    group  => $group,
    source => "puppet:///modules/${module_name}/mirrorbrain/populate-fallback.sh",
  }

  file { "${home_dir}/update-latest-symlink.sh":
    owner  => $user,
    group  => $group,
    source => "puppet:///modules/${module_name}/mirrorbrain/update-latest-symlink.sh",
  }
  ##########################


  $conntrack_max = '131072'
  # Double conntrack to ensure we can handle lots of connections
  file { '/etc/sysctl.d/30-conntrack.conf':
    ensure  => present,
    content => "net.nf_conntrack_max = ${conntrack_max}
",
    # Without invoking this procps service, the sysctl.d defaults aren't
    # properly loaded on boot under 14.04 LTS
    notify  => Exec['reprocess-sysctld'],
  }

  exec { 'reprocess-sysctld':
    command => '/usr/sbin/service procps start',
    unless  => "/sbin/sysctl net.nf_conntrack_max | grep '${conntrack_max}'",
    path    => ['/bin', '/sbin'],
  }


  ## Managing PostgreSQL
  ##########################
  ##
  ##########################
  if $manage_pgsql {
    class { 'postgresql::server':
    }

    postgresql::server::db { $pg_database:
      user     => $pg_username,
      password => $pg_password,
    }

    postgresql::server::role { 'datadog':
      password_hash => postgresql_password('datadog', $pg_password),
    }

    postgresql::server::grant { "datadog_${pg_database}":
      privilege   => 'SELECT',
      object_type => 'ALL TABLES IN SCHEMA',
      db          => $pg_database,
      role        => 'datadog',
    }

    class { 'datadog_agent::integrations::postgres':
      host     => 'localhost',
      dbname   => $pg_database,
      username => 'datadog',
      password => $pg_password,
      require  => [
        Class['postgresql::server'],
        Postgresql::Server::Grant["datadog_${pg_database}"],
      ],
    }
  }
  ##########################


  file { $mirrorbrain_conf:
    owner   => $user,
    group   => $group,
    content => template("${module_name}/mirrorbrain/mirrorbrain.conf.erb"),
  }

  file { $mirmon_conf:
    owner   => $user,
    group   => $group,
    content => template("${module_name}/mirrorbrain/mirmon.conf.erb"),
  }

  # Updating our TIME file allows us to easily tell how far mirrors have drived
  file { '/usr/local/bin/mirmon-time-update':
    owner   => 'root',
    mode    => '0755',
    content => "#!/bin/sh
date \"+%s\" > /srv/releases/jenkins/TIME
",
    require => File[$docroot],
  }

  ## Cron tasks
  #############
  cron { 'mirrorbrain-time-update':
    command => '/usr/local/bin/mirmon-time-update',
    user    => 'root',
    minute  => 2,
    require => File['/usr/local/bin/mirmon-time-update'],
  }

  cron { 'mirmon-status-page':
    command => "/usr/bin/mirmon -q -get update -c ${mirmon_conf}",
    user    => 'root',
    minute  => '15',
    require => File[$mirmon_conf],
  }

  cron { 'mirrorbrain-ping-mirrors':
    command => '/usr/bin/mirrorprobe',
    user    => 'root',
    minute  => '*/30',
    require => File[$mirrorbrain_conf],
  }

  # Scan our mirrors, will run as many concurrent jobs as their are processors
  # on the machine
  cron { 'mirrorbrain-scan':
    command => "/usr/bin/mb scan --quiet --jobs ${::processorcount} --all",
    user    => 'root',
    # See < https://issues.jenkins-ci.org/browse/INFRA-671>
    minute  => '0',
    require => File[$mirrorbrain_conf],
  }

  # perform regular clean up of our postgresql database
  cron { 'mirrorbrain-db-cleanup':
    command => '/usr/bin/mb db vacuum',
    user    => 'root',
    hour    => 2,
    minute  => 42,
    require => File[$mirrorbrain_conf],
  }

  cron { 'mirmon-update-mirror-list':
    command => '/usr/bin/mb export --format=mirmon > /srv/releases/mirror_list',
    user    => 'root',
    minute  => '30',
    hour    => '4',
    require => File[$mirrorbrain_conf],
  }

  # Sync all our Jenkins releases to our dependent mirrors
  # See <https://issues.jenkins-ci.org/browse/INFRA-694>
  cron { 'mirrorbrain-sync-releases':
    command => "cd ${home_dir} && ./sync.sh",
    minute  => '0',
    user    => $user,
    require => File["${home_dir}/sync.sh"],
  }
  #############

  # dbd-pgsql is required to allow mod_dbd to communicate with PostgreSQL
  package { 'libaprutil1-dbd-pgsql':
    ensure  => present,
    require => Class['apache'],
  }

  $dbd_conf = '/etc/apache2/mods-available/dbd.conf'
  $geoip_conf = '/etc/apache2/mods-available/geoip.conf'

  file { $dbd_conf:
    owner   => 'root',
    group   => 'root',
    content => template("${module_name}/mirrorbrain/dbd.conf.erb"),
  }

  file { '/etc/apache2/mods-enabled/dbd.conf':
    ensure  => link,
    target  => $dbd_conf,
    require => [
        File[$dbd_conf],
        Package['libaprutil1-dbd-pgsql'],
    ],
    notify  => Service['apache2'],
  }

  file { $geoip_conf:
    owner   => 'root',
    group   => 'root',
    require => Apache::Mod['geoip'],
    source  => "puppet:///modules/${module_name}/mirrorbrain/geoip.conf",
  }

  file { '/etc/apache2/mods-enabled/geoip.conf':
    ensure  => link,
    target  => $geoip_conf,
    require => [
        File[$geoip_conf],
    ],
    notify  => Service['apache2'],
  }

  file { $apache_log_dir:
    ensure => directory,
  }

  # This is dumb.
  exec { 'mirrorbrain-mkdirp':
    command => "/bin/mkdir -p ${docroot}",
    creates => $docroot,
  }

  apache::vhost { $server_name:
    serveraliases     => [
      'mirrors.jenkins-ci.org',
    ],
    port              => 80,
    serveradmin       => 'infra@lists.jenkins-ci.org',
    docroot           => $docroot,
    access_log_format =>  '\"%{X-Forwarded-For}i\" %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\" want:%{WANT}e give:%{GIVE}e r:%{MB_REALM}e %{X-MirrorBrain-Mirror}o %{MB_CONTINENT_CODE}e:%{MB_COUNTRY_CODE}e ASN:%{ASN}e P:%{PFX}e size:%{MB_FILESIZE}e %{Range}i forw:%{x-forwarded-for}i',
    access_log_pipe   => "|/usr/bin/rotatelogs ${apache_log_dir}/access.log.%Y%m%d%H%M%S 604800",
    error_log_file    => "${server_name}/error.log",
    require           => [
        File[$apache_log_dir],
        Package['apache2-utils'], # For log rotation
        Exec['mirrorbrain-mkdirp'],
    ],
    override          => ['All'],
    aliases           => [
      {
        alias => '/mirmon/icons',
        path  => '/usr/share/mirmon/icons',
      },
    ],
    directories       => [
      {
        path            => $docroot,
        options         => 'FollowSymLinks Indexes',
        allow_override  => ['All'],
        custom_fragment => '
            MirrorBrainEngine On
            MirrorBrainDebug Off
            FormGET On
            MirrorBrainHandleHEADRequestLocally Off

            # we serve most files from mirrors, but as a fallback,
            # this slow server has everything.
            MirrorBrainFallback na us http://archives.jenkins-ci.org/

            # Do not redirect for files smaller than 4096 bytes
            MirrorBrainMinSize 4096
            ## NOTE: Re-enabling these exclude rules will kill our bandwidth allocation.
            #MirrorBrainExcludeUserAgent rpm/4.4.2*
            #MirrorBrainExcludeUserAgent *APT-HTTP*

            MirrorBrainExcludeMimeType application/pgp-keys
            MirrorBrainExcludeMimeType text/html
        ',
      },
      {
        path           => '/usr/share/mirmon/icons',
        options        => 'None',
        allow_override => ['None'],
      },
    ],
  }
}
