require 'fileutils'
require 'pathname'
require 'open3'
require 'set'
require 'shellwords'
require 'yaml'

module LuxDeploy
  # Recipe layout: this file and its siblings live under
  # recipes/lib/deploy/, so ROOT points here and `templates/` sits
  # right next to us (no gem root anymore).
  ROOT ||= Pathname.new(__dir__)
  VERSION ||= '0.2.0'

  # Branches that select `.env` instead of `.env.staging`.
  MAIN_BRANCHES ||= %w[master main]

  # Server-side conventions. Not config-tunable because doctor and the
  # deploy flow both hardcode these paths in the host setup. A different
  # caddy/systemd layout means a different recipe.
  PORT_RANGE  ||= (3010..3990).step(10).to_a
  CADDY_SITES ||= '/etc/caddy/sites'
  SYSTEMD_DIR ||= '/etc/systemd/system'

  class Error < StandardError
    def to_s
      "ERROR: #{super}"
    end
  end

  # Host-supplied defaults that sit under the user's .yaml. Set once by a
  # wrapping plugin/Hammerfile (e.g. lux-fw seeds 'lux-web' / 'lux-apps'),
  # consumed by Config.new. Empty by default so the recipe stays "generic".
  @defaults = {}

  class << self
    attr_reader :defaults

    def set_defaults(hash)
      @defaults = (hash || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end
  end
end

require_relative 'config'
require_relative 'ssh'
require_relative 'template'
require_relative 'doctor'
require_relative 'context'
require_relative 'manifest'
require_relative 'commands'
require_relative 'hammer'
