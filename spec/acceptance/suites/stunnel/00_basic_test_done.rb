require 'spec_helper_acceptance'

test_name 'nfs basic'

describe 'nfs basic' do

  servers = hosts_with_role( hosts, 'nfs_server' )
  clients = hosts_with_role( hosts, 'client' )

  ssh_allow = <<-EOM
    include '::tcpwrappers'
    include '::iptables'

    tcpwrappers::allow { 'sshd':
      pattern => 'ALL'
    }

    iptables::add_tcp_stateful_listen { 'i_love_testing':
      order => '8',
      client_nets => 'ALL',
      dports => '22'
    }
  EOM

  let(:manifest) {
    <<-EOM
      include '::nfs'

      #{ssh_allow}
    EOM
  }

  let(:hieradata) {
    <<-EOM
---
nfs::simp_iptables : true
nfs::server : '#NFS_SERVER#'
# Set us up for a basic server for right now (no Kerberos)

# These two need to be paired in our case since we expect to manage the Kerberos
# infrastructure for our tests.
nfs::simp_krb5 : false
nfs::secure_nfs : false
nfs::is_server : #IS_SERVER#
nfs::server::client_ips : 'ALL'
    EOM

  }

  context 'setup' do
    hosts.each do |host|
      it 'should work with no errors' do
        hdata = hieradata.dup
        if servers.include?(host)
          hdata.gsub!(/#NFS_SERVER#/m, fact_on(host, 'fqdn'))
          hdata.gsub!(/#IS_SERVER#/m, 'true')
        else
          hdata.gsub!(/#NFS_SERVER#/m, servers.last.to_s)
          hdata.gsub!(/#IS_SERVER#/m, 'false')
        end

        set_hieradata_on(host, hdata)
        apply_manifest_on(host, manifest, :catch_failures => true)
      end

      it 'should be idempotent' do
        apply_manifest_on(host, manifest, :catch_changes => true)
      end
    end
  end

  context "as a server" do
    servers.each do |host|
      let(:manifest) {
        <<-EOM
          #{ssh_allow}

          include '::nfs'

          file { '/srv/nfs_share':
            ensure => 'directory',
            owner  => 'root',
            group  => 'root',
            mode   => '0644'
          }

          file { '/srv/nfs_share/test_file':
            ensure  => 'file',
            owner   => 'root',
            group   => 'root',
            mode    => '0644',
            content => 'This is a test'
          }

          nfs::server::export { 'nfs4_root':
            client      => ['*'],
            export_path => '/srv/nfs_share',
            sec         => ['sys'],
          }

          File['/srv/nfs_share'] -> Nfs::Server::Export['nfs4_root']
        EOM
      }

      it 'should export a directory' do
        apply_manifest_on(host, manifest)
      end
    end
  end

  context "as a client" do
    clients.each do |host|
      servers.each do |server|
        it "should mount a directory on the #{server} server" do
          server_fqdn = fact_on(server, 'fqdn')

          host.mkdir_p("/mnt/#{server}")
          on(host, %(puppet resource mount /mnt/#{server} ensure=mounted fstype=nfs4 device='#{server_fqdn}:/srv/nfs_share' options='sec=sys'))
          on(host, %(grep -q 'This is a test' /mnt/#{server}/test_file))
          on(host, %{puppet resource mount /mnt/#{server} ensure=unmounted})
        end
      end
    end
  end
end
