require 'yaml'
require 'aws-sdk'

require_relative 'miq_ec2_vm/miq_ec2_vm'
require_relative 'ssa_queue'

module AmazonSsaSupport
  class SsaQueueExtractor
    CATEGORIES = %w(accounts services software system).freeze
    attr_reader :my_instance, :ssaq

    def initialize(aws_args)
      raise ArgumentError, "Region must be specified." if aws_args[:region].nil?
      @aws_args     = aws_args
      @extractor_id = @aws_args[:extractor_id]
      @region       = @aws_args[:region]

      @ec2          = @aws_args[:ec2] || Aws::EC2::Resource.new(region: @region)
      @my_instance  = @ec2.instance(@extractor_id)
      @ssaq         = SsaQueue.new(@aws_args)
      @exit_code    = nil
    end

    def extract_loop
      $log.debug("#{self.class.name}.#{__method__} entered")
      @ssaq.request_loop do |req|
        $log.debug("#{self.class.name}.#{__method__} got message #{req[:sqs_msg].message_id}")
        process_request(req)
        return @exit_code if @exit_code
        $log.debug("#{self.class.name}.#{__method__} waiting for next message")
      end
    end

    def process_request(req)
      req_type = req[:request_type]
      $log.debug("#{self.class.name}.#{__method__}: processing request - #{req_type}")
      case req_type
      when :extract
        do_extract(req)
      when :exit, :reboot, :shutdown
        do_ers(req)
      else
        $log.error("#{self.class.name}.#{__method__}: Unrecognized request #{req_type}")
        @ssaq.delete_request(req)
      end
      $log.debug("#{self.class.name}.#{__method__}: completed processing request - #{req_type}")
    end

    def do_extract(req)
      @ssaq.delete_request(req)
      extract_reply = @ssaq.new_reply(req)
      begin
        ec2_vm = MiqEC2Vm.new(req[:ec2_id], @my_instance, @ec2)
        categories = req[:categories] || CATEGORIES
        $log.debug("categories: #{categories.inspect}")
        $log.info("MiqEC2Vm: #{ec2_vm.class.name} - categories = [ #{categories.join(', ')} ]")
        categories.each do |cat|
          xml = ec2_vm.extract(cat)
          extract_reply.add_category(cat, xml)
        end
      rescue => err
        extract_reply.error = err.to_s
        $log.error(err.to_s)
        $log.error(err.backtrace.join("\n"))
      ensure
        extract_reply.reply
        ec2_vm.unmount if ec2_vm
      end
    end

    def do_ers(req)
      if req[:extractor_id] != @extractor_id
        if req_target_exists?(req)
          $log.debug("#{self.class.name}.#{__method__}: re-queueing request: #{req[:sqs_msg].id}")
          @ssaq.requeue_request(req)
        else
          $log.debug("#{self.class.name}.#{__method__}: deleting request: #{req[:sqs_msg].id}")
          @ssaq.delete_request(req)
        end
        return
      end
      @exit_code = req[:request_type]
      @ssaq.delete_request(req)
      @ssaq.send_ers_reply(req)
    end

    def req_target_exists?(req)
      @ec2.instances[req[:extractor_id]].exists?
    end
    private :req_target_exists?
  end
end
