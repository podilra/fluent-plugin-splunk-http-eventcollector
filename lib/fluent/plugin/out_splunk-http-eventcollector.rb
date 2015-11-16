=begin

  Copyright (C) 2013 Keisuke Nishida

  Licensed to the Apache Software Foundation (ASF) under one
  or more contributor license agreements.  See the NOTICE file
  distributed with this work for additional information
  regarding copyright ownership.  The ASF licenses this file
  to you under the Apache License, Version 2.0 (the
  "License"); you may not use this file except in compliance
  with the License.  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing,
  software distributed under the License is distributed on an
  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
  KIND, either express or implied.  See the License for the
  specific language governing permissions and limitations
  under the License.

=end

module Fluent

class SplunkHTTPEventcollectorOutput < BufferedOutput
  Plugin.register_output('splunk-http-eventcollector', self)

  config_param :server, :string, :default => 'localhost:8088'
  config_param :verify, :bool, :default => true
  config_param :token, :string, :default => nil

  # Event parameters
  config_param :host, :string, :default => nil # TODO: auto-detect
  config_param :index, :string, :default => nil
  config_param :source, :string, :default => '{TAG}'
  config_param :sourcetype, :string, :default => '_json'

  config_param :post_retry_max, :integer, :default => 5
  config_param :post_retry_interval, :integer, :default => 5

  def initialize
    super
    require 'net/http/persistent'
    require 'time'
    @idx_indexers = 0
    @indexers = []
  end

  def configure(conf)
    super

    case @source
    when '{TAG}'
      @source_formatter = lambda { |tag| tag }
    else
      @source_formatter = lambda { |tag| @source.sub('{TAG}', tag) }
    end

    @time_formatter = lambda { |time| time.to_s }
    @formatter = lambda { |record| record.to_json }

    if @server.match(/,/)
      @indexers = @server.split(',')
    else
      @indexers = [@server]
    end
  end

  def start
    super
    @http = Net::HTTP::Persistent.new 'fluent-plugin-splunk-http-eventcollector'
    @http.verify_mode = OpenSSL::SSL::VERIFY_NONE unless @verify
    @http.override_headers['Content-Type'] = 'application/json'
    @http.override_headers['User-Agent'] = 'fluent-plugin-splunk-http-eventcollector/0.0.1'
    $log.debug "initialized for splunk-http-eventcollector"
  end

  def shutdown
    # NOTE: call super before @http.shutdown because super may flush final output
    super

    @http.shutdown
    $log.debug "shutdown from splunk-http-eventcollector"
  end

  def format(tag, time, record)
    if @time_formatter
      time_str = "#{@time_formatter.call(time)}: "
    else
      time_str = ''
    end

    #record.delete('time')
    event = "#{time_str}#{@formatter.call(record)}\n"

    [tag, event].to_msgpack
  end

  def chunk_to_buffers(chunk)
    buffers = {}
    chunk.msgpack_each do |tag, event|
      (buffers[@source_formatter.call(tag)] ||= []) << event
    end
    return buffers
  end

  def write(chunk)
    chunk_to_buffers(chunk).each do |source, messages|
      uri = URI get_baseurl
      post = Net::HTTP::Post.new uri.request_uri
      post['Authorization'] = "Splunk #{token}"
      post.body = messages.join('')
      $log.debug "POST #{uri}"
      # retry up to :post_retry_max times
      1.upto(@post_retry_max) do |c|
        response = @http.request uri, post
        $log.debug "=>(#{c}/#{@post_retry_max} #{response.code} (#{response.message})"
        if response.code == "200"
          # success
          break
        elsif response.code.match(/^40/)
          # user error
          $log.error "#{uri}: #{response.code} (#{response.message})\n#{response.body}"
          break
        elsif c < @post_retry_max
          # retry
          $log.debug "#{uri}: Retrying..."
          sleep @post_retry_interval
          next
        else
          # other errors. fluentd will retry processing on exception
          # FIXME: this may duplicate logs when using multiple buffers
          raise "#{uri}: #{response.message}"
        end
      end
    end
  end

  def get_baseurl
    base_url = ''
    server = @indexers[@idx_indexers];
    @idx_indexers = (@idx_indexers + 1) % @indexers.length
    base_url = "https://#{server}/services/collectors"
    base_url
  end
end

end