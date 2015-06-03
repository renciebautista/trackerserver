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
		@config = YAML.load_file('config/server.conf')

		name = @config['tigserver']['name']
		version = @config['tigserver']['version']

		@tigip = @config['tigserver']['ip']
		@tigport = @config['tigserver']['port']
		@connect = "<?xml version=\"1.0\"?><Tig><Client.Connect Name=\"#{name}\" Version=\"#{version}\" /></Tig>"
		puts @connect
		@socket = socket
		@socket.send(@connect, 0, @tigip.to_s , @tigport.to_i)
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
		response = Thread.new do
			begin
			  loop {
				new_msg = Thread.start(@socket.recvfrom(65536)) do | msg, sender |
					# puts msg
					xml = Document.new(msg)
					xmldoc = XPath.match(xml, "Tig/Call.Resource")
					if !xmldoc.empty?
						if getAttribute(xml, "Call.Resource","Status").to_s == "Granted"
							# puts getAttribute(xml, "Call.Resource","Status").to_s
							call = Thread.new do
								begin
									client = Mysql2::Client.new(
									  :host => @config['database']['host'], 
									  :username => @config['database']['username'],
									  :password => @config['database']['password'],
									  :database => @config['database']['database']
									)

									number = getAttribute(xml, "Tetra","Ssi")
									result = client.query("SELECT train_id,train_radios.id,head
										FROM train_radios
										INNER JOIN radios on train_radios.radio_id = radios.id
										WHERE ssi = #{number}");

										if result.count > 0
											result.each do |row|
												train_id = row["train_id"].to_s
												id = row["id"].to_s
												if row["head"] == 0
													client.query("UPDATE train_radios SET head = 0 WHERE train_id = '#{train_id}'")
													client.query("UPDATE train_radios SET head = 1 WHERE id = '#{id}'")
												end
											end
										end
									client.close
								rescue  Exception => e
									listen
									puts response.to_s + "MySql Server cannot be found!"
								end
							end
							puts call.to_s + "Radio Call.Resource"
						end
					end
					
					xmldoc2 = XPath.match(xml, "Tig/Subscriber.Location")
					if !xmldoc2.empty?
						log = Thread.new do
							begin
								client = Mysql2::Client.new(
										:host => @config['database']['host'], 
										:username => @config['database']['username'],
										:password => @config['database']['password'],
										:database => @config['database']['database']
									)

								mcc = getAttribute(xml, "Tetra","Mcc")
								mnc = getAttribute(xml, "Tetra","Mnc")
								ssi = getAttribute(xml, "Tetra","Ssi")
								name = getAttribute(xml, "Name","Name")
								uplink = getAttribute(xml, "Uplink","Rssi")
								speed = 0
								if(!getAttribute(xml, "PositionFix","Speed").nil?)
									speed = getAttribute(xml, "PositionFix","Speed")
								end

								course = getAttribute(xml, "PositionFix","Course")
								alt = getAttribute(xml, "PositionFix","Altitude")
								error = getAttribute(xml, "PositionFix","MaximumPositionError")

								lat = convertDegreeAngleToDouble(getAttribute(xml, "Latitude","Degrees"),getAttribute(xml, "Latitude","Minutes"),getAttribute(xml, "Latitude","Seconds"))

								lng = convertDegreeAngleToDouble(getAttribute(xml, "Longitude","Degrees"),getAttribute(xml, "Longitude","Minutes"),getAttribute(xml, "Longitude","Seconds"))

								# check if radio exist and active
								query = "SELECT * FROM radios
									WHERE id NOT IN (SELECT radio_id FROM train_radios )
									AND radios.active = 1
									AND mcc = #{mcc}
									AND mnc = #{mnc}
									AND ssi = #{ssi}"

								radio_result = client.query(query);
								if radio_result.count > 0 
									radio_result.each do |row|
											radio_id = row["id"].to_s
											mcc = row["mcc"].to_s
											mnc = row["mnc"].to_s
											ssi = row["ssi"].to_s
											tracker_code = row["tracker_code"].to_s
											image_index = row["image_index"].to_s
											client.query("INSERT INTO radio_logs (radio_id, mcc, mnc, ssi, tracker_code,
												subscriber_name, uplink, speed, course, alt, max_pos_error, lat, lng, image_index)
											   VALUES ('#{radio_id}', '#{mcc}', '#{mnc}', '#{ssi}', '#{tracker_code}',
												'#{name}', '#{uplink}', '#{speed}', '#{course}', '#{alt}', '#{error}', '#{lat}', '#{lng}', '#{image_index}')")
										end
								else
									query2 = "SELECT trains.id,head,trains.train_code,trains.train_desc,mcc,mnc,ssi,tracker_code, trains.image_index
									FROM tracker.train_radios
									INNER JOIN radios on train_radios.radio_id = radios.id
									INNER JOIN trains on train_radios.train_id = trains.id
									WHERE mcc = #{mcc}
									AND mnc = #{mnc}
									AND ssi = #{ssi}"
									
									result = client.query(query2);
									if result.count > 0
										result.each do |row|
											train_id = row["id"].to_s
											train_code = row["train_code"].to_s
											train_desc = row["train_desc"].to_s
											mcc = row["mcc"].to_s
											mnc = row["mnc"].to_s
											ssi = row["ssi"].to_s
											tracker_code = row["tracker_code"].to_s
											image_index = row["image_index"].to_s
											head = row["head"].to_s
											client.query("INSERT INTO logs (train_id,train_code, train_desc, mcc, mnc, ssi, tracker_code, head,
												subscriber_name, uplink, speed, course, alt, max_pos_error, lat, lng, image_index)
											   VALUES ('#{train_id}','#{train_code}', '#{train_desc}', '#{mcc}', '#{mnc}', '#{ssi}', '#{tracker_code}', '#{head}',
												'#{name}', '#{uplink}', '#{speed}', '#{course}', '#{alt}', '#{error}', '#{lat}', '#{lng}', '#{image_index}')")
										end
									end
								end	
								client.close
							rescue  Exception => e
								listen
								puts response.to_s + "MySql Server cannot be found!"
							end

						end
						puts log.to_s + "Radio Subscriber.Location"
					end

					xmldoc3 = XPath.match(xml, "Tig/Client.Connected")
					if !xmldoc3.empty?
						if getAttribute(xml, "Client.Connected","Success").to_s == "1"
							connected = Thread.new do
								begin
									client = Mysql2::Client.new(
									  :host => @config['database']['host'], 
									  :username => @config['database']['username'],
									  :password => @config['database']['password'],
									  :database => @config['database']['database']
									)
									timestamp = Time.now
									client.query("UPDATE settings SET last_update = '#{timestamp}' WHERE id = 1")
									client.close
								rescue  Exception => e
									listen
									puts response.to_s + "Tetra Server cannot be found!"
								end	
							end
						end
					end
					puts new_msg.to_s + "Radio Activity"
				end
			}
			rescue  Exception => e
				listen
				puts response.to_s + "Tetra Server cannot be found!"
			end

			
	  end
  end

  def send
	every_so_many_seconds(4) do
		  # p Time.now
		   # @socket.send(@connect, 0, @tigip , @tigport)
		begin
			@socket.send(@connect, 0, @tigip , @tigport)

			# response = Thread.new do
			# 	begin
			# 	client = Mysql2::Client.new(
			# 	  :host => @config['database']['host'], 
			# 	  :username => @config['database']['username'],
			# 	  :password => @config['database']['password'],
			# 	  :database => @config['database']['database']
			# 	)
			# 	timestamp = Time.now
			# 	client.query("UPDATE settings SET last_update = '#{timestamp}' WHERE id = 1")
			# 	client.close
			# 	rescue  Exception => e
			# 		listen
			# 		puts response.to_s + "MySql Server cannot be found!"
			# 	end
			# end
			
		rescue
			handle_error
		ensure
			# this_code_is_always_executed
		end
		  
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