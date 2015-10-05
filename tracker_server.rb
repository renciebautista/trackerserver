#!/usr/bin/env ruby
require 'yaml'
require 'socket'
require 'mysql2'
require 'rexml/document'
require 'logger'
require 'net/http'
include REXML

# daemonize 
Process.daemon(true,false)
 
# write pid
pid_file = File.dirname(__FILE__) + "#{__FILE__}.pid"
File.open(pid_file, 'w') {|f| f.write Process.pid }

class Client
	def initialize(socket,config)
		@log = Logger.new( 'log.txt', 'daily' )

		# this takes a hash of options, almost all of which map directly
		# to the familiar database.yml in rails
		# See http://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/MysqlAdapter.html
		@ip = '0.0.0.0'
		@config = config
		@default = 4 # default time 
		@lifetime = @default

		@url = @config['webserver']['url']
		@send = @config['webserver']['send']

		@index = 0
		name = @config['tigserver']['name']
		version = @config['tigserver']['version']

		@tigport = @config['tigserver']['txport']
		@connect = "<?xml version=\"1.0\"?><Tig><Client.Connect Name=\"#{name}\" Version=\"#{version}\" /></Tig>"
		
		@socket = socket
		listen

		@received = false
		@cnt = 0
		send

		# upload
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
			  loop do
					new_msg = Thread.start(@socket.recvfrom(65536)) do | msg, sender |
						xml = Document.new(msg)

						xmldoc3 = XPath.match(xml, "Tig/Client.Connected")
						if !xmldoc3.empty?
							if getAttribute(xml, "Client.Connected","Success").to_s == "1"
								life = getAttribute(xml, "Client.Connected","Lifetime").to_s.to_i / 3
								if life < 3
									@lifetime = 1
								else
									@lifetime = life
								end
								@ip = sender[3].to_s
								brodcast('1')
								@received = true
								@cnt = 0
							else
								@lifetime = @default
								brodcast('0')

								@received = false
							end
						end

						# check if a radio call is made
						xmldoc = XPath.match(xml, "Tig/Call.Resource")
						if !xmldoc.empty?
							if getAttribute(xml, "Call.Resource","Status").to_s == "Granted"
								@cnt = 0
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
										@log.error e.to_s + " MySql Server cannot be found!"
										#puts response.to_s + "MySql Server cannot be found!"
									end
								end
								# puts call.to_s + "Radio Call.Resource"
							end
						end
						
						# check if a data is sent from tnx
						xmldoc2 = XPath.match(xml, "Tig/Subscriber.Location")
						if !xmldoc2.empty?
							@cnt = 0
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

									send_log = false
									id = ''
									code = ''
									radio_result = client.query(query);
									if radio_result.count > 0 
										send_log = true
										radio_result.each do |row|
												radio_id = row["id"].to_s
												mcc = row["mcc"].to_s
												mnc = row["mnc"].to_s
												ssi = row["ssi"].to_s
												id = ssi
												tracker_code = row["tracker_code"].to_s
												code = tracker_code
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
										
										result = client.query(query2)
										if result.count > 0
											send_log = true
											result.each do |row|
												train_id = row["id"].to_s
												train_code = row["train_code"].to_s
												train_desc = row["train_desc"].to_s
												mcc = row["mcc"].to_s
												mnc = row["mnc"].to_s
												ssi = row["ssi"].to_s
												id = ssi
												tracker_code = row["tracker_code"].to_s
												code = tracker_code
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

									if send_log
										if @send
									 		send1020(id,code,lat,lng)
									 	end
									end
								rescue  Exception => e
									@log.error e.to_s + " MySql Server cannot be found!"
									#puts response.to_s + "MySql Server cannot be found!"
								end

							end
							#puts log.to_s + "Radio Subscriber.Location"
						end

						#puts new_msg.to_s + "Radio Activity"
						# puts @received
						
					end
				end
			rescue  Exception => e
				@log.error e.to_s + " Tetra Server cannot be found!"
				@received = false
			end
	  end
  end

  def brodcast(status)
  	# ip = @ips[@index].join(",")
  	ip = @ip
  	lifetime = @lifetime
  	data = "tnx|#{ip}|#{status}|#{lifetime}"
  	puts data.to_s
  	socket = UDPSocket.open
		socket.setsockopt(Socket::IPPROTO_IP, Socket::IP_TTL, 1)
		socket.send(data, 0, "225.4.5.6", 5000)
		socket.close 
  end

  def send1020(id,code,lat,lng)
  	puts 'send'
 	if @send
 		uri = URI(@url)
 		today = Time.now.strftime("%Y%m%d%H%M%S").to_i
 		param = id.to_s+','+code.to_s+','+today.to_s+','+lat.to_s+','+lng.to_s
		res = Net::HTTP.post_form(uri, 'cmd' => 'loc', 'param' => param)
		puts res.body
 	end
  end

  def send
		every_so_many_seconds() do
			client = Mysql2::Client.new(
			  :host => @config['database']['host'], 
			  :username => @config['database']['username'],
			  :password => @config['database']['password'],
			  :database => @config['database']['database']
			)
			# puts self.to_s+ ' => '+Time.now.to_s + " => " + @lifetime.to_s
			@ips = client.query("SELECT ip FROM servers").each(:as => :array)

			begin

				if !@received
					@ip = '0.0.0.0'
					@lifetime = @default
					brodcast('0')
				else
					brodcast('1')
				end
				listen

				@ips.each do |ip|
					@socket.send(@connect, 0, ip.join(","), @tigport)
				end
				

			rescue Exception => e
				@log.error e.to_s
				#handle_error
			ensure
				# this_code_is_always_executed
			end
		end
  end

  def every_so_many_seconds()
	  last_tick = Time.now
	  loop do
		sleep 0.1
		if Time.now - last_tick >= @lifetime
		  last_tick += @lifetime
		  yield
		end
	  end
	end

end

config = YAML.load_file('config/server.conf')
socket = UDPSocket.new
socket.bind("", config['tigserver']['rxport'])
Client.new(socket,config)