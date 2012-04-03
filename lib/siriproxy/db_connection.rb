# -*- encoding : utf-8 -*-
require 'mysql'

def db_connect(host, user, pass, database)
		begin
			db_connection=Mysql.real_connect(host, user, pass, database)
			#db_connection.autocommit(false);
			puts "Mysql Server version: " + db_connection.get_server_info+ "\nConnection and dataset ok"
			return db_connection
		rescue Mysql::Error => e 
			puts "Error code: #{e.errno}"
    			puts "Error message: #{e.error}"
     			puts "Error SQLSTATE: #{e.sqlstate}" if e.respond_to?("sqlstate")
			puts "We could not establish a connection to the dataset.\nInfo: Make sure you have created the database and edited options"
     			exit(1)
		end
end

def db_disconnect(db_connection)
	ensure
     		db_connection.close if db_connection 

	puts "Connection to Database Closed"	
end


