#!/usr/bin/env oo-ruby

require 'json'
require 'tempfile'
require 'fileutils'
require 'optparse'
require 'fiddle'

def set_process_name(name)
    RUBY_PLATFORM.index("linux") or return
    Fiddle::Function.new(
        DL::Handle["prctl"], [
            Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP,
            Fiddle::TYPE_LONG, Fiddle::TYPE_LONG,
            Fiddle::TYPE_LONG
        ], Fiddle::TYPE_INT
    ).call(15, name, 0, 0, 0)
end

set_process_name("send-zabbix-data")
$0 = "send-zabbix-data " + ARGV.join(" ")


# Variables for Zabbix.  If you don't have a Zabbix server,
# these will simply be ignored
ZABBIX_SERVER  = ENV['ZABBIX_SERVER_IP']
ZABBIX_PORT    = ENV['ZABBIX_SERVER_PORT']
ZABBIX_SENDER  = ENV['OPENSHIFT_ZABBIX_AGENT_DIR'] + '/bin/zabbix_sender'
ZABBIX_RUN_DIR = ENV['OPENSHIFT_ZABBIX_AGENT_DIR'] + '/run'

class GearData
  attr_reader :result

  def initialize
    @result = Hash.new
  end

  def update
    get_cgroup_data
    get_quota_data
    get_ulimit_data
    get_system_data
    get_meminfo
  end

  def get_cgroup_data
    JSON.load(%x[ oo-cgroup-read report ]).each do |k,v|
      unless k.end_with?('.stat')
        @result["cgroup.#{k}"] = v
        next
      end
      v.each do |sk, sv|
        next if k == 'memory.stat' and sk.start_with?('total_')
        @result["cgroup.#{k}.#{sk}"] = sv
      end
    end
    
  end

  def get_quota_data
    %x[ quota -vw ].lines.each do |l|
      next unless l.start_with?('/')
      data = l.split()
      @result.merge!({ 'quota.home.blocks_used' => data[1],
                       'quota.home.blocks_limit' => data[3],
                       'quota.home.inodes_used' => data[4],
                       'quota.home.inodes_limit' => data[6] })
    end
  end

  def get_ulimit_data
    # nofile is per-process, and so not really useful unless
    # you compare each process against it's limit
    # data['ulimit.nofile'] = %x[ lsof ].lines.to_a.length()
    @result['ulimit.nproc'] = %x[ ps -eL ].lines.to_a.length()
  end

  def get_system_data
    @result['system.uptime'], idle_time = File.open('/proc/uptime').read.split
    @result['system.cpu.load[percpu,avg1]'], @result['system.cpu.load[percpu,avg5]'], \
      @result['system.cpu.load[percpu,avg15]'], procs, lastpid = \
      File.open('/proc/loadavg').read.split
  end

  def get_meminfo
    File.open('/proc/meminfo').lines.each do |line|
      field_name, value, unit = line.strip.split
      case field_name.chomp(':')
      when 'MemTotal'
        @result['vm.memory.size[total]'] = value
      when 'MemFree'
        @result['vm.memory.size[free]'] = value
      when 'Buffers'
        @result['vm.memory.size[buffers]'] = value
      when 'Cached'
        @result['vm.memory.size[cached]'] = value
      when 'SwapTotal'
        @result['system.swap.size[,total]'] = value
      when 'SwapFree'
        @result['system.swap.size[,free]'] = value
      else
        # puts "Unrecognized #{field_name.chomp(':')}"
      end
    end
  end
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

  puts cmd if verbose
  system(cmd)
  retval = $?.exitstatus
  tmpfile.unlink

  return retval
end

def log_data(entries)
  ts = Time.now.strftime('%Y/%m/%dT%H:%M:%SZ%z')
  log = File.open(ENV['OPENSHIFT_ZABBIX_AGENT_DIR'] + '/log/zagent.log', 'a+')
  log.write(entries.collect { |k, v| "#{ts} #{k} #{v}\n" }.join(""))
  log.close
end

def main(gd, options={})
  gd.update
  log_data(gd.result)
  send_data(gd.result, options[:verbose])
end

#### MAIN PROGRAM ####

options = { :verbose => false }

optparse = OptionParser.new do|opts|
  opts.on( '-h', '--help', 'Display this screen' ) do
    puts opts
    exit
  end

  opts.on( '-i', '--interval SECONDS', "data gathering interval" ) do |i|
    options[:interval] = i
  end

  opts.on( '-v', '--verbose', "Verbose output" ) do
    options[:verbose] = true
  end
end
optparse.parse!

gd = GearData.new
if options[:interval].nil?
  main(gd, options)
else
  loop do
    begin
      main(gd, options)
    rescue Exception => e
      # Don't die
      puts e.inspect
    end
    sleep options[:interval].to_i
  end
end
