require 'fcntl'
require 'socket'
require 'stringio'

require 'nack/builder'
require 'nack/error'
require 'nack/netstring'

module Nack
  class Server
    def self.run(*args)
      new(*args).start
    end

    attr_accessor :config, :app, :file
    attr_accessor :ppid, :server, :heartbeat

    def initialize(config, options = {})
      self.config = config
      self.file   = options[:file]

      self.ppid   = Process.ppid

      at_exit { close }

      self.server = UNIXServer.open(file)
      self.server.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)

      readable, writable = IO.select([self.server], nil, nil, 3)

      if readable && readable.first == self.server
        self.heartbeat = server.accept_nonblock
        self.heartbeat.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
      else
        warn "No heartbeat connected"
        exit 1
      end

      trap('TERM') { exit }
      trap('INT')  { exit }
      trap('QUIT') { close }

      self.app = load_config
      load_json_lib!
    rescue Exception => e
      handle_exception(e)
    end

    def load_json_lib!
      begin
        require 'json'
      rescue LoadError
        require 'rubygems'
        require 'json'
      end
    end

    def try_load_json_lib
      load_json_lib!
    rescue LoadError
    end

    def load_config
      cfgfile = File.read(config)
      eval("Nack::Builder.new {( #{cfgfile}\n )}.to_app", TOPLEVEL_BINDING, config)
    end

    def close
      server.close if server && !server.closed?
      heartbeat.close if heartbeat && !heartbeat.closed?
      File.unlink(file) if file && File.exist?(file)
    end

    def start
      heartbeat.write "#{$$}\n"
      heartbeat.flush

      clients = []
      buffers = {}

      loop do
        listeners = clients + [heartbeat]
        listeners << server unless server.closed?

        readable, writable = nil
        begin
          readable, writable = IO.select(listeners, nil, nil, 60)
        rescue Errno::EBADF
        end

        if (server.closed? || heartbeat.closed?) && clients.empty?
          return close
        end

        if ppid != Process.ppid
          return close
        end

        next unless readable

        readable.each do |sock|
          if sock == heartbeat && heartbeat.eof?
            return close
          elsif sock == server
            client = server.accept_nonblock
            client.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
            clients << client
          else
            client, buf = sock, buffers[sock] ||= ''

            begin
              buf << client.read_nonblock(1024)
            rescue EOFError
              handle sock, StringIO.new(buf)
              buffers.delete(client)
              clients.delete(client)
            end
          end
        end
      end

      nil
    rescue SystemExit, Errno::EINTR
      # Ignore
    rescue Exception => e
      handle_exception(e)
    end

    def handle(sock, buf)
      status  = 500
      headers = { 'Content-Type' => 'text/html' }
      body    = ["Internal Server Error"]

      env, input = nil, StringIO.new

      NetString.read(buf) do |data|
        if env.nil?
          env = JSON.parse(data)
        elsif data.length > 0
          input.write(data)
        else
          break
        end
      end

      sock.close_read
      input.rewind

      method, path = env['REQUEST_METHOD'], env['PATH_INFO']

      env = env.merge({
        "rack.version" => Rack::VERSION,
        "rack.input" => input,
        "rack.errors" => $stderr,
        "rack.multithread" => false,
        "rack.multiprocess" => true,
        "rack.run_once" => false,
        "rack.url_scheme" => ["yes", "on", "1"].include?(env["HTTPS"]) ? "https" : "http"
      })

      status, headers, body = app.call(env)

      begin
        NetString.write(sock, status.to_s)
        NetString.write(sock, headers.to_json)

        body.each do |part|
          NetString.write(sock, part) if part.length > 0
        end
        NetString.write(sock, "")
      ensure
        body.close if body.respond_to?(:close)
      end
    rescue Exception => e
      NetString.write(sock, exception_to_json(e))
    ensure
      sock.close_write
    end

    def handle_exception(e)
      if heartbeat && !heartbeat.closed?
        heartbeat.write("#{exception_to_json(e)}\n")
        heartbeat.flush
        heartbeat.close
        exit 1
      else
        raise e
      end
    end

    def exception_as_json(e)
      { :name    => e.class.name,
        :message => e.message,
        :stack   => e.backtrace.join("\n") }
    end

    def exception_to_json(e)
      try_load_json_lib

      exception = exception_as_json(e)
      if exception.respond_to?(:to_json)
        exception.to_json
      else
        <<-JSON
          { "name": #{exception[:name].inspect},
            "message": #{exception[:message].inspect},
            "stack": #{exception[:stack].inspect} }
        JSON
      end
    end
  end
end
