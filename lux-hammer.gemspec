version = File.read File.expand_path '.version', File.dirname(__FILE__)

Gem::Specification.new 'lux-hammer', version do |s|
  s.summary     = 'Thor-inspired tiny CLI builder'
  s.description = 'Minimal, zero-dependency Thor-inspired CLI builder for Ruby. Class DSL and block DSL, subcommands, options, auto help, color helpers.'
  s.authors     = ['Dino Reic']
  s.email       = 'reic.dino@gmail.com'
  # Ship the prebuilt macOS GUI bundle so `hammer --gui` works on install
  # (vendored .app; source lives under gui/HammerGUI in the repo).
  gui_app       = Dir['./gui/Hammer.app/**/*'].select { |f| File.file?(f) }
  s.files       = Dir['./lib/**/*.rb'] + Dir['./recipes/**/*.rb'] + gui_app + ['./.version', './README.md', './AGENTS.md', './bin/hammer']
  s.bindir      = 'bin'
  s.executables = ['hammer']
  s.homepage    = 'https://github.com/dux/hammer'
  s.license     = 'MIT'

  s.required_ruby_version = '>= 2.7'

  s.add_development_dependency 'minitest', '~> 5.0'
end
