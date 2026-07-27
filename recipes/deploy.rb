#!/usr/bin/env hammer
# desc: SSH/rsync deploy - Caddy + systemd + atomic releases

desc <<~TXT
  Stupid-simple SSH/rsync deploy (Caddy + systemd + atomic releases).

  Quickstart:
    deploy app:init          # copy templates into ./config/deploy/
    deploy doctor            # check & prep the host
    deploy up                # deploy current branch

  Server:
    deploy server:log        # tail the systemd journal
    deploy server:ssh        # shell into the current release
    deploy server:restart    # restart the web service
    deploy log --log errors  # dump a remote log
TXT

# The engine lives in the lux-deploy gem. This recipe used to carry a vendored
# copy of it, which drifted a full major version behind and would have deployed
# 0.2 semantics onto a 0.3 host. Requiring the gem keeps one engine.
#
# Not a gemspec dependency - lux-hammer stays zero-dependency, and only this
# one recipe needs it. The require is what enforces it, at invocation time.
begin
  require 'lux_deploy'
rescue LoadError
  abort 'lux-deploy is not installed. Run: gem install lux-deploy'
end

# Auto-load the app's deploy bootstrap, if present, before tasks fire.
# A consumer can inject Ruby (e.g. a pre-deploy hook) without writing a
# custom Hammerfile.
init = File.join(Dir.pwd, 'config', 'deploy', 'init.rb')
load init if File.file?(init)

# `self` here is the recipe's Builder context - same surface a Hammerfile gets.
# No templates_dir: the gem falls back to its own LuxDeploy::ROOT/templates,
# which is what the standalone `lux-deploy` binary uses too.
LuxDeploy::Hammer.register(self)
