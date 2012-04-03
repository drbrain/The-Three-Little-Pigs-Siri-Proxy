# -*- encoding : utf-8 -*-
require 'pony'  
#send email function
def sendemail(config)
  #Lets also send an email comming soon
  if @config.send_email
    begin
      Pony.mail(
        :to        => @config.email_to,
        :from      => @config.email_from,
        :subject   => @config.email_subject,
        :html_body => @config.email_message
      )
      puts "[Email - SiriProxy] Expired key email sent to [#{@config.email_to}]"
    rescue 
      puts "[Email - SiriProxy] Warning Cannot send mail. Check your ~/.siriproxy/config.yml"            
    end
  end        
  #Done with email
end
  
