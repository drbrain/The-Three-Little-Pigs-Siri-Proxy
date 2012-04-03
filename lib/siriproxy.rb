require 'eventmachine'
require 'zlib'
require 'pp'
require "siriproxy/version"
require "siriproxy/functions"

class String
  def to_hex(seperator=" ")
    bytes.to_a.map{|i| i.to_s(16).rjust(2, '0')}.join(seperator)
  end
end



class SiriProxy
  
  def initialize()
    #Lets make the Ctrl+C a little more user friendly
    trap("INT") {quit_on_int}
    def quit_on_int
      puts "\nTerminating TLP version [#{SiriProxy::VERSION}]"
      puts "Done, bye bye!!!"
      exit
    end
    
    
    # @todo shouldnt need this, make centralize logging instead
    $LOG_LEVEL = $APP_CONFIG.log_level.to_i
    #Version support added
    puts "Initializing TLP version [#{SiriProxy::VERSION}]"

    #Initialization of event machine variables overider +epoll mode on by default
EM.epoll
    EM.set_descriptor_table_size( 60000 )

    #Database connection
    my_db = db_connect

    #initialize config
    @conf = ConfigProxy.instance
    conf_dao = ConfigDao.instance
    conf_dao.connect_to_db(my_db)
    @conf = conf_dao.getsettings
    @conf.active_connections = 0
    conf_dao.update(@conf)
    EM.threadpool_size = @conf.max_threads
    #end of config

    #initialize key controller
    @key_dao = KeyDao.instance
    @key_dao.connect_to_db(my_db)

    #initialize key stats controller
    @keystatistics_dao = KeyStatisticsDao.instance
    @keystatistics_dao.connect_to_db(my_db)

    #Initialize The Assistant Controller
    @assistant_dao = AssistantDao.instance
    @assistant_dao.connect_to_db(my_db)

    #Initialize the Stats controller and setup it
    statistics_dao = StatisticsDao.instance
    statistics_dao.connect_to_db(my_db)

    #Initialize new stats
    statistics = statistics_dao.getstats
    statistics.uptime = 0
    statistics_dao.savestats(statistics)

    #Initialize Client Controller
    @clients_dao = ClientsDao.instance
    @clients_dao.connect_to_db(my_db)

    @APP_CONFIG.assistant_dao     = @assistant_dao
    @APP_CONFIG.clients_dao       = @clients_dao
    @APP_CONFIG.conf              = @conf
    @APP_CONFIG.key_dao           = @key_dao
    @APP_CONFIG.keystatistics_dao = @keystatistics_dao

    #Print email config
    if $APP_CONFIG.send_email=='ON' or $APP_CONFIG.send_email=='on'
      puts '[Info - SiriProxy] Email notifications are [ON]!'
    else
      puts '[Info - SiriProxy] Email notifications are [OFF]!'
    end
    
    #Print the server if its publc or not
    if $APP_CONFIG.private_server=="ON" or $APP_CONFIG.private_server=="on"
      puts '[Info - SiriProxy] Private Server [ON]!'
    else
      puts '[Info - SiriProxy] Private Server [OFF]!'
    end
    #Set default to revent errors.
    if $APP_CONFIG.happy_hour_countdown==nil
      puts '[Info - SiriProxy] Happy Hour Countdown not set in config.yml. Using default'
      $APP_CONFIG.happy_hour_countdown = 21600
    end
    #Start The EventMacine
    EventMachine.run do
      begin
        puts "Starting SiriProxy on port #{$APP_CONFIG.port}.."
        EventMachine::start_server('0.0.0.0', $APP_CONFIG.port, SiriProxy::Connection::Iphone, $APP_CONFIG) { |conn|
          $stderr.puts "start conn #{conn.inspect}" if $LOG_LEVEL > 3
          conn.plugin_manager = SiriProxy::PluginManager.new()
          conn.plugin_manager.iphone_conn = conn
        }
   
        puts "Server is Up and Running"
        @timer=5 # set the timer value
        @timer2=60 # The expirer
        @timer3=900 # the expirer of old assistnats
        #
        #Temp fix and guard to apple not replying command failed
         EventMachine::PeriodicTimer.new(@timer2){
            puts "[Expirer - SiriProxy] Expiring past 20 hour Keys"
           @totalkeysexpired = @key_dao.expire_24h_hour_keys
           puts @totalkeysexpired
           for i in (0...@totalkeysexpired)
               sendemail()
           end
          
           @keystatistics_dao.delete_keystats
            puts "[Stats - SiriProxy] Cleaning up key statistics"
           
         }
         
        #Delete old assistants. If i am not mistaken each assistant is valid for only 7 days.
        #Delete 14 days assistants for database cleaning
# EventMachine::PeriodicTimer.new(@timer3){
# puts "[Expirer - SiriProxy] DELETING past 14 DAYS Assistants"
# @assistant_dao.delete_expired_assistants
# }
        
        
        
        @unbanned=false
        EventMachine::PeriodicTimer.new(@timer){
          statistics = statistics_dao.getstats
          statistics.elapsed += @timer
          statistics.uptime += @timer
          statistics.happy_hour_elapsed += @timer
          #if there is autokeyban to off there is no need for happy hour
          if $APP_CONFIG.enable_auto_key_ban=='OFF' or $APP_CONFIG.enable_auto_key_ban=='OFF'
            statistics.happy_hour_elapsed = 0
          end
          
          #Happy hour enabler only if autokeyban is on
          if statistics.happy_hour_elapsed > $APP_CONFIG.happy_hour_countdown and ($APP_CONFIG.enable_auto_key_ban == 'ON' or $APP_CONFIG.enable_auto_key_ban == 'on') and @unbanned == false
            @key_dao.unban_keys
           @unbanned=true
            puts "[Happy hour - SiriProxy] Unbanning Keys and Doors are open"
          end
          #only when autokeyban is on
          if statistics.happy_hour_elapsed > ($APP_CONFIG.happy_hour_countdown + 300) and ($APP_CONFIG.enable_auto_key_ban == 'ON' or $APP_CONFIG.enable_auto_key_ban == 'on') and @unbanned == true
            @key_dao.ban_keys
            puts "[Happy hour - SiriProxy] Banning Keys and Doors are Closed"
            statistics.happy_hour_elapsed = 0
            @unbanned=false
          end
          #KeyLoad DropDown
          if statistics.elapsed > @conf.keyload_dropdown_interval
            @overloaded_keys_count = @key_dao.findoverloaded.count
            if (@overloaded_keys_count>0)
              @overloaded_keys = @key_dao.findoverloaded
              for i in 0..(@overloaded_keys_count-1)
                @oldkeyload=@overloaded_keys[i].keyload
                @overloaded_keys[i].keyload = @overloaded_keys[i].keyload - @conf.keyload_dropdown
                @key_dao.setkeyload(@overloaded_keys[i])
                puts "[Keys - SiriProxy] Decreasing Keyload for Key id=[#{@overloaded_keys[i].id}] and Decreasing keyload from [#{@oldkeyload}] to [#{@overloaded_keys[i].keyload}]"
              end
            end
            statistics.elapsed = 0
          end
          
          statistics_dao.savestats(statistics)
          @conf.active_connections = EM.connection_count
          conf_dao.update(@conf)
          ### Per Key based connections
          @max_connections = @conf.max_connections
          @availablekeys = @key_dao.list4Skeys.count
          if @availablekeys==0 #this is not needed anymore!
            @max_connections=700#max mem
          elsif @availablekeys>0
            @max_connections = @conf.max_connections * @availablekeys
          end
          puts "[Info - SiriProxy] Uptime [#{statistics.uptime}] Active connections [#{@conf.active_connections}] Max connections [#{@max_connections}]"
          
        }
        EventMachine::PeriodicTimer.new(@conf.keyload_dropdown_interval){ #fix for server crash
          
        }
      rescue RuntimeError => err
        if err.message == "no acceptor"
          raise "Cannot start the server on port #{$APP_CONFIG.port} - are you root, or have another process on this port already?"
        else
          raise
        end
      end
    end
  end
end
