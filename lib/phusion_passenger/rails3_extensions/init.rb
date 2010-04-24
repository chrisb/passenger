require 'phusion_passenger/constants'

module PhusionPassenger

module Rails3Extensions
	def self.init!(options)
		if !AnalyticsLogging.install!(options)
			# Remove code to save memory.
			PhusionPassenger::Rails3Extensions.send(:remove_const, :AnalyticsLogging)
			PhusionPassenger.send(:remove_const, Rails3Extensions)
		end
	end
	
	class AnalyticsLogging < Rails::LogSubscriber
		def self.install!(options)
			analytics_logger = options["analytics_logger"]
			return false if !analytics_logger
			
			# If the Ruby interpreter supports GC statistics then turn it on
			# so that the info can be logged.
			GC.enable_stats if GC.respond_to?(:enable_stats)
			
			subscriber = self.new
			Rails::LogSubscriber.add(:action_controller, subscriber)
			Rails::LogSubscriber.add(:active_record, subscriber)
			
			index = Rails::Application.middleware.find_index do |m|
				m.klass.name == 'ActionDispatch::ShowExceptions'
			end
			Rails::Application.middleware.insert_after(index,
				ExceptionLogger, analytics_logger)
			# Make sure Rails rebuilds the middleware stack.
			Rails::Application.instance.instance_variable_set(:'@app', nil)
			
			ActiveSupport::Benchmarkable.class_eval do
				include ASBenchmarkableExtension
				alias_method_chain :benchmark, :passenger
			end
			
			return true
		end
		
		def start_processing(event)
			log = Thread.current[PASSENGER_ANALYTICS_WEB_LOG]
			if log
				log.message("Controller action: #{event.payload[:controller]}##{event.payload[:action]}")
				log.begin_measure("framework request processing")
			end
		end
		
		def process_action(event)
			log = Thread.current[PASSENGER_ANALYTICS_WEB_LOG]
			if log
				log.end_measure("framework request processing")
				view_begin = event.payload[:view_begin]
				if view_begin
					view_end = event.payload[:view_end]
					log.measured_time_points("view rendering", view_begin, view_end)
				else
					log.measured_interval(event.payload[:view_runtime] * 1000)
				end
			end
		end
		
		def sql(event)
			log = Thread.current[PASSENGER_ANALYTICS_WEB_LOG]
			if log
				sql_base64 = [event.payload[:sql]].pack("m")
				sql_base64.gsub!("\n", "")
				sql_base64.strip!
				if event.payload[:name]
					name = event.payload[:name].strip
				else
					name = "SQL"
				end
				log.measured_time_points("DB BENCHMARK: #{sql_base64} #{name}",
					event.time, event.end)
			end
		end
		
		class ExceptionLogger
			def initialize(app, analytics_logger)
				@app = app
				@analytics_logger = analytics_logger
			end
			
			def call(env)
				@app.call(env)
			rescue Exception => e
				log_analytics_exception(env, e) if env[PASSENGER_TXN_ID]
				raise e
			end
		
		private
			def log_analytics_exception(env, exception)
				log = @analytics_logger.new_transaction(
					env[PASSENGER_GROUP_NAME],
					:exceptions)
				begin
					request = ActionDispatch::Request.new(env)
					controller = request.parameters['controller'].humanize + "Controller"
					action = request.parameters['action']
					
					request_txn_id = env[PASSENGER_TXN_ID]
					message = exception.message
					message = exception.to_s if message.empty?
					message = [message].pack('m')
					message.gsub!("\n", "")
					backtrace_string = [exception.backtrace.join("\n")].pack('m')
					backtrace_string.gsub!("\n", "")
					if action
						controller_action = "#{controller}##{action}"
					else
						controller_action = controller
					end
					
					log.message("Request transaction ID: #{request_txn_id}")
					log.message("Message: #{message}")
					log.message("Class: #{exception.class.name}")
					log.message("Backtrace: #{backtrace_string}")
					log.message("Controller action: #{controller_action}")
				ensure
					log.close
				end
			end
		end
		
		module ASBenchmarkableExtension
			def benchmark_with_passenger(message = "Benchmarking", *args)
				log = Thread.current[PASSENGER_ANALYTICS_WEB_LOG]
				if log
					log.measure("BENCHMARK: #{message}") do
						benchmark_without_passenger(message, *args) do
							yield
						end
					end
				else
					benchmark_without_passenger(message, *args) do
						yield
					end
				end
			end
		end
	end
end

end