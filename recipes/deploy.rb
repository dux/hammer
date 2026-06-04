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

# Loads the bundled lib (config/ssh/template/doctor/context/manifest/
# commands/hammer) - same require chain the gem's lib/lux_deploy.rb had.
require_relative 'lib/deploy/boot'

# Auto-load the app's deploy bootstrap, if present, before tasks fire.
# A consumer can inject Ruby (e.g. a pre-deploy hook) without writing a
# custom Hammerfile.
init = File.join(Dir.pwd, 'config', 'deploy', 'init.rb')
load init if File.file?(init)

# `self` here is the recipe's Builder context - same surface a Hammerfile
# gets. Pass templates_dir explicitly since there's no gem ROOT to fall
# back to; it resolves to recipes/lib/deploy/templates.
LuxDeploy::Hammer.register(self, templates_dir: File.join(__dir__, 'lib/deploy/templates'))
