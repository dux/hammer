require_relative 'test_helper'

class VersionTest < Minitest::Test
  def test_format_renders_a_dotted_triple
    {
      'v123'   => '1.2.3',
      'v1123'  => '11.2.3',
      'v81'    => '0.8.1',
      'v5'     => '0.0.5',
      'v100'   => '1.0.0',
      'v1234'  => '12.3.4',
      'v1.2.3' => 'v1.2.3',
      'dev'    => 'dev',
      ''       => ''
    }.each do |raw, want|
      assert_equal want, Hammer::Version.format(raw), "format(#{raw.inspect})"
    end
  end

  def test_version_is_the_formatted_string
    assert_equal Hammer::Version.string, Hammer::VERSION
    refute_match(/^v/, Hammer::VERSION)
  end

  def test_version_is_a_valid_gem_version
    assert_equal Hammer::VERSION, Gem::Version.new(Hammer::VERSION).to_s
  end
end
