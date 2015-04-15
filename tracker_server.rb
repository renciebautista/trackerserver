require 'yaml'
require 'socket'
require 'mysql2'
require 'rexml/document'
include REXML


class Client
	def initialize(socket)
		# this takes a hash of options, almost all of which map directly
		# to the familiar database.yml in rails
		# See http://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/MysqlAdapter.html
		config = YAML.load_file('config/server.conf')
		@client = Mysql2::Client.new(
		  host: config['database']['host'], 
		  username: config['database']['username'],
		  password: config['database']['password'],
		  database: config['database']['database'],
		)
		name = config['tigserver']['name']
		version = config['tigserver']['version']
		@tigip = config['tigserver']['ip']
		@tigport = config['tigserver']['port']
		@connect = '<?xml version="1.0"?><Tig><Client.Connect Name="#{name}" Version="#{version}" /></Tig>'
		@socket = socket
		@socket.send(@connect, 0, @tigip , @tigport)
		listen
    send
	end

	def getAttribute(xml, tagname, attribute)
		XPath.first(xml, "//#{tagname}/@#{attribute}")
	end

	def convertDegreeAngleToDouble(degrees,minutes,seconds)
		degrees.to_s.to_f + (minutes.to_s.to_f / 60) + (seconds.to_s.to_f / 3600)
	end

	def listen
		Thread::abort_on_exception = true
		@response = Thread.new do
			begin
			  loop {
				Thread.start(@socket.recvfrom(65536)) do | msg, sender |
					xml = Document.new(msg)
					xmldoc = XPath.match(xml, "Tig/Subscriber.Location")
					if !xmldoc.empty?
						mcc = getAttribute(xml, "Tetra","Mcc")
						mnc = getAttribute(xml, "Tetra","Mnc")
						ssi = getAttribute(xml, "Tetra","Ssi")

						name = getAttribute(xml, "Name","Name")

						uplink = getAttribute(xml, "Uplink","Rssi")

						speed = getAttribute(xml, "PositionFix","Speed")
						course = getAttribute(xml, "PositionFix","Course")
						alt = getAttribute(xml, "PositionFix","Altitude")
						error = getAttribute(xml, "PositionFix","MaximumPositionError")

						lat = convertDegreeAngleToDouble(getAttribute(xml, "Latitude","Degrees"),getAttribute(xml, "Latitude","Minutes"),getAttribute(xml, "Latitude","Seconds"))

						lng = convertDegreeAngleToDouble(getAttribute(xml, "Longitude","Degrees"),getAttribute(xml, "Longitude","Minutes"),getAttribute(xml, "Longitude","Seconds"))

						result = @client.query("SELECT head,trains.train_code,trains.train_desc,mcc,mnc,ssi,tracker_code FROM tracker.train_radios
							INNER JOIN radios on train_radios.radio_id = radios.id
							INNER JOIN trains on train_radios.train_id = trains.id
							WHERE mcc = #{mcc}
							AND mnc = #{mnc}
							AND ssi = #{ssi}");
						if result.count > 0
							result.each do |row|
							  	train_code = row["train_code"]
							  	train_desc = row["train_desc"]
							  	mcc = row["mcc"]
							  	mnc = row["mnc"]
							  	ssi = row["ssi"]
							  	tracker_code = row["tracker_code"]
							  	head = row["head"]
							  	puts @client.query("INSERT INTO logs (train_code, train_desc, mcc, mnc, ssi, tracker_code, head,
							 		subscriber_name, uplink, speed, course, alt, max_pos_error, lat, lng)
		    	                   VALUES ('#{train_code}', '#{train_desc}', '#{mcc}', '#{mnc}', '#{ssi}', '#{tracker_code}', '#{head}',
		    	                   	'#{name}', '#{uplink}', '#{speed}', '#{course}', '#{alt}', '#{error}', '#{lat}', '#{lng}')")
							end
						end
					# else
					# 	puts 'Empty'
					end

					xmldoc2 = XPath.match(xml, "Tig/Call.Data")
					if !xmldoc2.empty?
						number = getAttribute(xml, "CallId","CallNumber")
						result = @client.query("SELECT train_id,train_radios.id,head
							FROM train_radios
							INNER JOIN radios on train_radios.radio_id = radios.id
							WHERE ssi = #{number}");

						if result.count > 0
							result.each do |row|
							  	train_id = row["train_id"]
							  	id = row["id"]
							  	if row["head"] == 0
							  		@client.query("UPDATE train_radios SET head = 0 WHERE train_id = '#{train_id}'")
							  		@client.query("UPDATE train_radios SET head = 1 WHERE id = '#{id}'")
							  	end
							end
						end
					end

			    end
		    }
			rescue  Exception => e
				listen
			  	puts @response.to_s + "Server cannot be found!"
			end

			
	  end
  end

  def send
	  every_so_many_seconds(4) do
		  # p Time.now
		  @socket.send(@connect, 0, @tigip , @tigport)
		  # Thread.kill(@response)
		  # listen
		end
  end

  def every_so_many_seconds(seconds)
	  last_tick = Time.now
	  loop do
	    sleep 0.1
	    if Time.now - last_tick >= seconds
	      last_tick += seconds
	      yield
	    end
	  end
	end

end


socket = UDPSocket.new
socket.bind("", 30512)
Client.new(socket)
