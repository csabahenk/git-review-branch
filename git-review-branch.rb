#!/usr/bin/env ruby

require 'optparse'
require 'ostruct'
require 'etc'

class CmdFail < StandardError
end

class Cmd

  def initialize *a
    @baseargs = a
  end

  def self.debug *a
  end

  def run *a
    kw = Hash === a[-1] ? a.pop : {}
    env, args = a.flatten.partition { |e| Hash === e }
    args = env + @baseargs + args
    o,wo = IO.pipe
    e,we = IO.pipe
    pid = Process.spawn *(args + [kw.merge(out:wo, err:we)])
    [we, wo].each &:close
    sa = [o,e]
    odata = {o => "", e => ""}
    until sa.empty?
      ia,_,_ = select sa
      ia.each { |f|
        v = f.read 1024
        v ? odata[f] << v : sa.delete(f)
      }
    end
    [o,e].each &:close
    _,s = Process.wait2 pid
    self.class.debug(args, s, odata.values)
    unless s.success?
      v = case true
      when s.exited?
        s.exitstatus
      when s.signaled?
        "signal #{s.termsig}"
      else
        raise "process terminated in unknown condition"
      end
      argv = args.map { |e| Hash === e ? nil : [e].flatten[-1] }.compact
      raise CmdFail, "#{argv.join " "} failed with #{v}#{odata[e].empty? ? "" : ": " + odata[e]}" 
    end
    odata[o]
  end

end

class CmdDbg < Cmd

  def self.debug args, stat, outs
    args = args.map { |x| Hash === x ? x.map { |k,v| "#{k}=#{v}" } : x }.flatten.join(" ")
    stat = stat.inspect.sub(/.*\spid\s+\d+\s/, "").sub(/\s*>\Z/, "")
    outs = %w[out err].zip outs.map { |d|
      d.inspect[1...-1] == d ? d : d.inspect
    }
    puts "DBG #{args} => #{stat}", *outs.map { |k,d|
         d.empty? ? nil : "  DBG #{k}: #{d}"
    }.compact
  end

end


CONF = OpenStruct.new user: Etc.getlogin, port: 29418, host: "review.openstack.org"

op = OptionParser.new
op.banner << <<EOS
 <change-id>

Build a git branch from patchsets of a Gerrit review entry,
specified by <change-id> (either the Gerrit review number or
the Change-Id).

Options:
EOS
addopt = proc { |*a|
  option = a.grep(/\A--/)[0].sub(/\A--/, "").sub(/([^a-zA-Z_-].*)?\Z/, "")
  defval = CONF.send option
  if defval
    a[-1][0...2] == "--" and a << ""
    a[-1].sub! /(.)$/, '\1 '
    a[-1] << "[default: #{defval}]"
  end
  op.on(*a) { |v| CONF.send "#{option}=", v }
}
[['-u', '--user U', 'Gerrit user'],
 ['-p', '--port P'],
 ['--host H'],
 ['--jsonhack', 'allow sloppy JSON stream parsing'],
 ['--patchno N', '--patch-number N', 'specify patchset number to align commits with'],
 ['-v', '--verbose'],
 ['--debug'],
 ['--branch[=B]', 'create named branch at result commit'],
 ['-r', '--remote R', 'Git remote for Gerrit']].each { |a| addopt[*a] }
op.parse!

unless $*.size == 1
  puts op
  exit 1
end

CONF.changeid = $*[0]

if CONF.respond_to? :branch
  CONF.branch ||= "patchsets-#{CONF.changeid}"
end

if CONF.verbose
  def info *a
    kw = {:break_line => true}.merge Hash === a[-1] ? a.pop : {}
    kw[:break_line] ? puts(*a): print(*a)
  end
else
  def info *a
  end
end

Cmdx = CONF.debug ? CmdDbg : Cmd

jsonfetch = begin
  require 'yajl'
  proc { |data| Yajl::Parser.new.parse(data) { |o| break o } }
rescue LoadError
  unless CONF.jsonhack
    STDERR.puts <<EOS
Yajl gem is missing.
Please install it with 'gem install yajl-ruby',
or enable a workaround with '--jsonhack'
EOS
    exit 1
  end
  require 'json'
  proc { |data| JSON.load data.split("\n")[0] }
end

git = Cmdx.new "git"

unless git.run(%w[status -z]).split("\0").map { |l| l.split(/ +/, 2)[0] } - %w[?? !!] == []
  STDERR.puts "Aborting: there are outstanding changes"
  exit 1
end

cdata = jsonfetch.call Cmdx.new("ssh").run "-p", CONF.port.to_s,
  "#{CONF.user}@#{CONF.host}",
  %w[gerrit query  --patch-sets  --format=json], CONF.changeid

CONF.remote ||= "ssh://#{CONF.user}@#{CONF.host}:#{CONF.port}/#{cdata["project"]}.git"

patches = {}.instance_eval {
  cdata["patchSets"].each { |ptch|
    self[Integer ptch["number"]] = OpenStruct.new ptch
  }
  self
}

info "Fetching #{patches.size} patchset versions ..."
patches.each { |n,ptch|
  begin
    git.run %w[cat-file -e], ptch.revision
  rescue CmdFail
    git.run "fetch", CONF.remote, ptch.ref
    unless git.run(%w[rev-parse FETCH_HEAD]).strip == ptch.revision
      raise "FETCH_HEAD mismatch for patch ##{n}"
    end
  end
  info "#{n} ", break_line:false
}
info

CONF.patchno ||= patches.keys.max
unless patches.include? CONF.patchno
  STDERR.puts "Aborting: there is no patchset version #{CONF.patchno}"
  exit 1
end

git.run %w[checkout --detach]

info "Cherry-picking patchset versions ..."
cherrymap = []
# ruby hashes preserve order, but I don't know
# of guarantee that the JSON we get from Gerrit
# provides patchset records in order, so better
# to get it sorted it here
patches.to_a.sort.each { |n,ptch|
  begin
    git.run %w[reset --hard], patches[CONF.patchno].revision + "^"
    git.run({"GIT_EDITOR"=> "sed -i -e '1 s/$/ [patchset #{n}]/'"}, %w[cherry-pick -e], ptch.revision)
    cherrymap << [n, git.run(%w[rev-parse HEAD]).strip]
    info "#{n}(^_^) ", break_line:false
  rescue CmdFail
    info "#{n}(>_<) ", break_line:false
  end
}
info

info "Building patchset branch ..."
n, gitid = cherrymap.shift
git.run %w[reset --hard], gitid
info "#{n} ", break_line:false
cherrymap.each { |n,gitid|
  git.run "checkout", gitid, "."
  git.run %w[commit -C], gitid
  info "#{n} ", break_line:false
}
info

if CONF.branch
  info "Creating branch #{CONF.branch} ..."
  git.run %w[checkout -b], CONF.branch
end
