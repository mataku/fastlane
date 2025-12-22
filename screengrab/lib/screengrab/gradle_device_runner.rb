require 'fastlane/helper/gradle_helper'
require_relative 'module'

module Screengrab
  # Handles test execution via Gradle Managed Devices
  class GradleDeviceRunner
    attr_reader :config, :android_env

    def initialize(config, android_env)
      @config = config
      @android_env = android_env
      @gradle_helper = nil
    end

    # Validates GMD configuration before execution
    def validate_configuration
      UI.user_error!("managed_device_name is required when use_gradle_managed_device is true") unless @config[:managed_device_name]

      gradle_path = resolve_gradle_path
      UI.user_error!("Couldn't find gradlew at path '#{gradle_path}'") unless File.exist?(gradle_path)

      @gradle_helper = Fastlane::Helper::GradleHelper.new(gradle_path: gradle_path)

      # Verify the managed device task exists
      device_task = gradle_task_for_device
      unless @gradle_helper.task_available?(device_task)
        UI.user_error!("Gradle task '#{device_task}' not found. Ensure your managed device '#{@config[:managed_device_name]}' is properly configured in build.gradle")
      end

      UI.message("Using Gradle Managed Device: #{@config[:managed_device_name]}")
    end

    # Executes tests via Gradle for a specific locale
    def execute_tests_for_locale(locale, test_classes, test_packages, launch_arguments)
      task = gradle_task_for_device
      flags = build_gradle_flags(locale, test_classes, test_packages, launch_arguments)

      UI.message("Executing Gradle task: #{task}")

      begin
        test_output = @gradle_helper.trigger(
          task: task,
          flags: flags,
          serial: '', # Not used for GMD
          print_command: true,
          print_command_output: true
        )
      rescue => ex
        UI.error("Gradle task execution failed: #{ex.message}")
        UI.error("Ensure your managed device '#{@config[:managed_device_name]}' is properly configured")
        return { success: false, output: ex.message }
      end

      # Parse output for failures
      if test_output.include?("BUILD FAILED")
        UI.error("Gradle build failed. Check the output above for details.")
        return { success: false, output: test_output }
      end

      if test_output.include?("FAILURES!!!") || test_output =~ /\d+ (test|tests) failed/
        return { success: false, output: test_output }
      end

      { success: true, output: test_output }
    end

    # Determines the device serial for the managed device
    # GMD devices appear as regular ADB devices after Gradle starts them
    def get_device_serial
      # After running a GMD test, the device should be visible via ADB
      # Wait briefly for device to be available
      max_retries = 10
      retry_count = 0

      while retry_count < max_retries
        adb = Fastlane::Helper::AdbHelper.new(
          adb_path: @android_env.adb_path,
          adb_host: @config[:adb_host]
        )
        devices = adb.load_all_devices

        if devices.any?
          device_serial = devices.first.serial
          UI.message("Found GMD device: #{device_serial}")
          return device_serial
        end

        sleep(2)
        retry_count += 1
      end

      UI.error("No devices found via ADB after #{max_retries} retries")
      UI.error("GMD should have started a device, but none are visible")
      nil
    end

    private

    def resolve_gradle_path
      gradle_path_param = @config[:gradle_path]
      project_dir = @config[:project_dir]

      if Pathname.new(gradle_path_param).absolute?
        File.expand_path(gradle_path_param)
      else
        File.expand_path(File.join(project_dir, gradle_path_param))
      end
    end

    # Constructs the Gradle task name for the managed device
    # Format: :<module>:<deviceName>DebugAndroidTest
    # Example: :app:pixelApi30DebugAndroidTest
    def gradle_task_for_device
      module_prefix = @config[:gradle_module] ? ":#{@config[:gradle_module]}" : ""
      device_name = @config[:managed_device_name]

      # The task name combines the device name with the build variant
      # For screenshot tests, we typically use Debug
      "#{module_prefix}:#{device_name}DebugAndroidTest"
    end

    # Builds Gradle flags including test instrumentation arguments
    def build_gradle_flags(locale, test_classes, test_packages, launch_arguments)
      flags = []

      # Add project directory
      flags << "-p #{@config[:project_dir].shellescape}"

      # Build instrumentation runner arguments
      test_runner_args = {}
      test_runner_args['testLocale'] = locale
      test_runner_args['appendTimestamp'] = @config[:use_timestamp_suffix].to_s
      test_runner_args['class'] = test_classes.join(',') if test_classes && test_classes.any?
      test_runner_args['package'] = test_packages.join(',') if test_packages && test_packages.any?

      # Add custom launch arguments
      if launch_arguments && launch_arguments.any?
        launch_arguments.each do |arg|
          # Parse "key value" format
          parts = arg.split(' ', 2)
          test_runner_args[parts[0]] = parts[1] if parts.length == 2
        end
      end

      # Convert to Gradle property format
      # -Pandroid.testInstrumentationRunnerArguments.key=value
      test_runner_args.each do |key, value|
        flags << "-Pandroid.testInstrumentationRunnerArguments.#{key.shellescape}=#{value.shellescape}"
      end

      flags.join(' ')
    end
  end
end
