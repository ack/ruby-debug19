require 'pp'
require 'stringio'
require 'socket'
require 'thread'
require 'ruby-debug-base'
require_relative 'ruby-debug/processor'

module Debugger
  self.handler = CommandProcessor.new
  
  # the port number used for remote debugging
  PORT = 8989 unless defined?(PORT)

  # What file is used for debugger startup commands.
  unless defined?(INITFILE)
    if RUBY_PLATFORM =~ /mswin/
      # Of course MS Windows has to be different
      INITFILE = 'rdebug.ini'
      HOME_DIR =  (ENV['HOME'] || 
                   ENV['HOMEDRIVE'].to_s + ENV['HOMEPATH'].to_s).to_s
    else
      INITFILE = '.rdebugrc'
      HOME_DIR = ENV['HOME'].to_s
    end
  end
  
  class << self
    # gdb-style annotation mode. Used in GNU Emacs interface
    attr_accessor :annotate

    # in remote mode, wait for the remote connection 
    attr_accessor :wait_connection

    # If set, a string to look for in caller() and is used to see
    # if the call stack is truncated.
    attr_accessor :start_sentinal 
    
    attr_reader :thread, :control_thread

    def interface=(value) # :nodoc:
      handler.interface = value
    end
    
    #
    # Starts a remote debugger.
    #
    def start_remote(host = nil, port = PORT, post_mortem = false)
      return if @thread
      return if started?

      self.interface = nil
      start
      self.post_mortem if post_mortem

      if port.kind_of?(Array)
        cmd_port, ctrl_port = port
      else
        cmd_port, ctrl_port = port, port + 1
      end

      start_control(host, ctrl_port)
      
      yield if block_given?
      
      mutex = Mutex.new
      proceed = ConditionVariable.new
      
      @thread = DebugThread.new do
        server = TCPServer.new(host, cmd_port)
        while (session = server.accept)
          self.interface = RemoteInterface.new(session)
          if wait_connection
            mutex.synchronize do
              proceed.signal
            end
          end
        end
      end
      if wait_connection
        puts "Waiting for connections on #{host}:#{cmd_port}"
        mutex.synchronize do
          proceed.wait(mutex)
        end
      end
    end
    alias start_server start_remote
    
    def start_control(host = nil, ctrl_port = PORT + 1) # :nodoc:
      raise "Debugger is not started" unless started?
      return if defined?(@control_thread) && @control_thread
      @control_thread = DebugThread.new do
        server = TCPServer.new(host, ctrl_port)
        while (session = server.accept)
          interface = RemoteInterface.new(session)
          processor = ControlCommandProcessor.new(interface)
          processor.process_commands
        end
      end
    end
    
    #
    # Connects to the remote debugger
    #
    def start_client(host = 'localhost', port = PORT)
      require "socket"
      interface = Debugger::LocalInterface.new
      socket = TCPSocket.new(host, port)
      if ENV['EMACS']
        print "\032\032starting\n" # mirrors non-remote --client
      else
        print "Connected.\n" # preserve old behavior
      end

      catch(:exit) do
        trap('INT') do
          STDERR.puts "\nABORTED"
          interface.finalize
          throw :exit
        end
        while true
          begin
            line = socket.gets
          rescue Errno::ECONNABORTED, Errno::ECONNRESET
            print "Disconnected\n"
            throw :exit
          end

          case line
          when nil
            break
          when /^PROMPT (.*)$/
            prompt = $1
            prompt = socket.gets.chomp # next is actual prompt
            sanity = socket.gets
            throw :exit unless sanity =~ /PROMPT/i
            input = interface.read_command(prompt)
            throw :exit unless input
            socket.puts input
          when /^CONFIRM (.*)$/
            input = interface.confirm($1)
            throw :exit unless input
            socket.puts input
          else
            print line
          end
        end
      end

      interface.finalize
      socket.close
    end
    
    # Runs normal debugger initialization scripts
    # Reads and executes the commands from init file (if any) in the
    # current working directory.  This is only done if the current
    # directory is different from your home directory.  Thus, you can
    # have more than one init file, one generic in your home directory,
    #  and another, specific to the program you are debugging, in the
    # directory where you invoke ruby-debug.
    def run_init_script(out = handler.interface)
      cwd_script_file  = File.expand_path(File.join(".", INITFILE))
      run_script(cwd_script_file, out) if File.exists?(cwd_script_file)

      home_script_file = File.expand_path(File.join(HOME_DIR, INITFILE))
      run_script(home_script_file, out) if File.exists?(home_script_file) and 
        cwd_script_file != home_script_file
    end

    #
    # Runs a script file
    #
    def run_script(file, out = handler.interface, verbose=false)
      interface = ScriptInterface.new(File.expand_path(file), out)
      processor = ControlCommandProcessor.new(interface)
      processor.process_commands(verbose)
    end
  end
end

module Kernel

  # Enters the debugger in the current thread after _steps_ line events occur.
  # Before entering the debugger startup script is read.
  #
  # Setting _steps_ to 0 will cause a break in the debugger subroutine
  # and not wait for a line event to occur. You will have to go "up 1"
  # in order to be back in your debugged program rather than the
  # debugger. Settings _steps_ to 0 could be useful you want to stop
  # right after the last statement in some scope, because the next
  # step will take you out of some scope.
  def debugger(steps = 1)
    Debugger.start unless Debugger.started?
    Debugger.run_init_script(StringIO.new)
    if 0 == steps
      Debugger.current_context.stop_frame = 0
    else
      Debugger.current_context.stop_next = steps
    end
  end
  alias breakpoint debugger unless respond_to?(:breakpoint)
end
