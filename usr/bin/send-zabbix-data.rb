#!/usr/bin/env oo-ruby

require 'json'
require 'tempfile'
require 'fileutils'
require 'optparse'

# Variables for Zabbix.  If you don't have a Zabbix server,
# these will simply be ignored
ZABBIX_SERVER  = ENV['ZABBIX_SERVER_IP']
ZABBIX_PORT    = ENV['ZABBIX_SERVER_PORT']
ZABBIX_SENDER  = ENV['OPENSHIFT_ZABBIX_AGENT_DIR'] + '/bin/zabbix_sender'
ZABBIX_RUN_DIR = ENV['OPENSHIFT_ZABBIX_AGENT_DIR'] + '/run'

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
  # nofile is per-process, and so not really useful unless
  # you compare each process against it's limit
  # data['ulimit.nofile'] = %x[ lsof ].lines.to_a.length()
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
  data['system.uptime'], idle_time = File.open('/proc/uptime').read.split
  data['system.cpu.load[percpu,avg1]'], data['system.cpu.load[percpu,avg5]'], data['system.cpu.load[percpu,avg15]'], procs, lastpid = \
    File.open('/proc/loadavg').read.split
  data.merge!(get_meminfo)
  return data
end

def get_meminfo
  data = Hash.new()
  File.open('/proc/meminfo').lines.each do |line|
    field_name, value, unit = line.strip.split
    case field_name.chomp(':')
    when 'MemTotal'
      data['vm.memory.size[total]'] = value
    when 'MemFree'
      data['vm.memory.size[free]'] = value
    when 'Buffers'
      data['vm.memory.size[buffers]'] = value
    when 'Cached'
      data['vm.memory.size[cached]'] = value
    when 'SwapTotal'
      data['system.swap.size[,total]'] = value
    when 'SwapFree'
      data['system.swap.size[,free]'] = value
    else
      # puts "Unrecognized #{field_name.chomp(':')}"
    end
  end

  return data
end

def send_data(entries, verbose = false)
  # Do not attempt to send data if there's no Zabbix server
  return 0 if not (ENV['ZABBIX_SERVER_IP'] and ENV['ZABBIX_SERVER_PORT'])
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

def log_data(entries)
  ts = Time.now.strftime('%Y/%m/%dT%H:%M:%SZ%z')
  log = File.open(ENV['OPENSHIFT_ZABBIX_AGENT_DIR'] + '/log/zagent.log', 'a+')
  log.write(entries.collect { |k, v| "#{ts} #{k} #{v}\n" }.join(""))
end

json_data = JSON.load(%x[ oo-cgroup-read report ])
entries = Hash.new()
json_data.each do |k,v|
  unless k.end_with?('.stat')
    puts "cgroup.#{k} = #{v}"
    entries["cgroup.#{k}"] = v
    next
  end
  v.each do |sk, sv|
    next if k == 'memory.stat' and sk.start_with?('total_')
    puts "cgroup.#{k}.#{sk} = #{sv}"
    entries["cgroup.#{k}.#{sk}"] = sv
  end
end
entries.merge!(get_quota_data)
entries.merge!(get_ulimit_data)
entries.merge!(get_system_data)

log_data(entries)
send_data(entries, true)
