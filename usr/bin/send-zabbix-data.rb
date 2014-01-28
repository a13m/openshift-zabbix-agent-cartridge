#!/usr/bin/env oo-ruby

require 'json'
require 'tempfile'
require 'fileutils'

ZABBIX_SERVER  = ENV['ZABBIX_SERVER_IP']
ZABBIX_PORT    = ENV['ZABBIX_SERVER_PORT']
ZABBIX_SENDER  = ENV['OPENSHIFT_ZABBIX_AGENT_DIR'] + '/bin/zabbix_sender'
ZABBIX_RUN_DIR = ENV['OPENSHIFT_ZABBIX_AGENT_DIR'] + '/run'

def get_cgroup_data
  keys = [ 'cpuacct.stat',
           'cpuacct.usage',
           'cpu.cfs_period_us',
           'cpu.cfs_quota_us',
           'cpu.rt_period_us',
           'cpu.rt_runtime_us',
           'cpu.stat',
           'memory.failcnt',
           'memory.limit_in_bytes',
           'memory.max_usage_in_bytes',
           'memory.memsw.failcnt',
           'memory.memsw.limit_in_bytes',
           'memory.memsw.max_usage_in_bytes',
           'memory.memsw.usage_in_bytes',
           'memory.stat',
           'memory.swappiness',
           'memory.usage_in_bytes',
         ]

  # This is ugly, because the file formats are not consistent
  data = {}

  keys.each do |k|
    if k.end_with?('.stat')
      data[k] = Hash.new()
      %x[ oo-cgroup-read #{k} ].lines.each do |line|
        subkey, subval = line.split()
        data[k][subkey] = subval.strip()
      end
    else
      data[k] = %x[ oo-cgroup-read #{k} ].strip()
    end
    # puts k
  end

  return data
end

def get_quota_data
  res = nil

  %x[ quota -vw ].lines.each do |l|
    next unless l.start_with?('/')
    data = l.split()
    res = { 'quota.home.blocks_used' => data[1],
            'quota.home.blocks_limit' => data[3],
            'quota.home.inodes_used' => data[4],
            'quota.home.inodes_limit' => data[6] }
  end
  return res
end

def get_ulimit_data
  data = Hash.new()
  data['ulimit.nofile'] = %x[ lsof ].lines.to_a.length()
  data['ulimit.nproc'] = %x[ ps -eL ].lines.to_a.length()
  return data
end

def get_system_data
  data = Hash.new()
  # TODO: read the following from /proc:
  #  uptime
  #  loadavg
  #  meminfo
  #  vmstat
end

def send_data(entries, verbose = true)
  puts "Sending this data:" if verbose

  # Create a temporary file for this class (where the data is stored)
  tmpfile = Tempfile.new('zabbix-sender-tmp-', "#{ZABBIX_RUN_DIR}/")
  entries.each do |k,v|
    line = ENV['OPENSHIFT_GEAR_DNS'] + " #{k} #{v}\n"

    puts line if verbose
    tmpfile << line
  end
  tmpfile.close()

  cmd = "#{ZABBIX_SENDER}"
  cmd += " -z #{ZABBIX_SERVER} -p #{ZABBIX_PORT} -i #{tmpfile.path} -s " + ENV['OPENSHIFT_GEAR_DNS']
  cmd += " -vv" if verbose
  cmd += " &> /dev/null" unless verbose

  puts cmd
  puts if verbose
  system(cmd)
  retval = $?.exitstatus
  # tmpfile.unlink

  return retval
end


json_data = get_cgroup_data
# puts JSON.dump(get_cgroup_data)
entries = Hash.new()
json_data.each do |k,v|
  next if k.start_with?('memory.stat.total_')
  unless k.end_with?('.stat')
    puts "cgroup.#{k} = #{v}"
    entries["cgroup.#{k}"] = v
    next
  end
  v.each do |sk, sv|
    puts "cgroup.#{k}.#{sk} = #{sv}"
    entries["cgroup.#{k}.#{sk}"] = sv
  end
end
entries.merge!(get_quota_data)
entries.merge!(get_ulimit_data)
entries.merge!(get_system_data)

send_data(entries, true)
