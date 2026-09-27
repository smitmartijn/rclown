require "test_helper"
require "minitest/mock"

class Rclone::BucketListerTest < ActiveSupport::TestCase
  setup { @lister = Rclone::BucketLister.new(providers(:cloudflare)) }

  test "parses an explicit JSON directory listing and empty list" do
    assert_equal [ "one", "two" ], @lister.send(:parse_bucket_list, '[{"Name":"two","IsDir":true},{"Name":"one","IsDir":true}]')
    assert_equal [], @lister.send(:parse_bucket_list, "[]")
  end

  test "malformed or incomplete output cannot become an empty account" do
    [ "", "garbage", "{}", '[{"Name":"a"}]', '[{"Name":"a","IsDir":false}]', '[{"Name":"","IsDir":true}]' ].each do |output|
      assert_raises(Rclone::Error) { @lister.send(:parse_bucket_list, output) }
    end
  end

  test "failed listing redacts credentials and removes its config" do
    config_path = nil
    process = Struct.new(:value).new(Struct.new(:success?).new(false))
    secret = providers(:cloudflare).secret_access_key
    capture = lambda do |*command, **options, &block|
      config_path = command.last
      assert_equal [ "rclone", "lsjson", "remote:", "--dirs-only", "--config" ], command.first(5)
      block.call(StringIO.new, StringIO.new, StringIO.new("failure #{secret}"), process)
    end
    Open3.stub :popen3, capture do
      error = assert_raises(Rclone::Error) { @lister.list }
      assert_not_includes error.message, secret
      assert_includes error.message, "[FILTERED]"
    end
    assert_not File.exist?(config_path)
  end

  test "timeout terminates the subprocess and reports discovery failure" do
    process = Struct.new(:pid).new(999999)
    killed = false
    capture = ->(*command, **options, &block) { block.call(StringIO.new, StringIO.new("[]"), StringIO.new, process) }
    Open3.stub :popen3, capture do
      Timeout.stub :timeout, ->(*) { raise Timeout::Error } do
        @lister.stub :terminate, ->(value) { killed = value == process } do
          error = assert_raises(Rclone::Error) { @lister.list }
          assert_match(/timed out/, error.message)
        end
      end
    end
    assert killed
  end
end
