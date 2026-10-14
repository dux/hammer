require_relative 'test_helper'
require 'tmpdir'

class VersionTest < Minitest::Test
  def test_read_yaml_and_plain_files
    Dir.mktmpdir do |dir|
      path = File.join(dir, '.version')
      {
        "version: 0.8.4\noffset: 3\n"         => '0.8.4',
        "# gem\nversion: 1.2.3  # stamped\n"  => '1.2.3',
        "0.8.2\n"                             => '0.8.2',
        "v3.9.8\n"                            => 'v3.9.8',
        "offset: 3\n"                         => nil,
        ''                                    => nil
      }.each do |body, want|
        File.write(path, body)
        got = Hammer::Version.read(path)
        want ? assert_equal(want, got, body.inspect) : assert_nil(got, body.inspect)
      end
    end
  end

  def test_read_missing_file
    assert_nil Hammer::Version.read('/nonexistent/.version')
  end

  def test_version_is_the_file_version
    assert_equal Hammer::Version.string, Hammer::VERSION
    assert_equal Hammer::Version.read(File.join(Hammer::Version::ROOT, '.version')), Hammer::VERSION
  end

  def test_version_is_a_valid_gem_version
    assert_equal Hammer::VERSION, Gem::Version.new(Hammer::VERSION).to_s
  end
end
