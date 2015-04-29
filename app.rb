require 'sinatra'
require 'sqlite3'
require 'rack'
require 'rack/contrib'
require 'yaml'
require 'haml'
require 'faraday'
require 'ruby-bandwidth'

$config = YAML.load(File.read("./config.yml"))
use Rack::PostBodyContentTypeParser

$application_id = nil
$domain = nil
$application_name = $config['application'] || 'Ruby Acme App'

$service_provider_token = nil
$service_provider_secret = nil

#connection for MMP requestss
$mmp = Faraday.new(:url => $config['base_mmp_url']) do |faraday|
  faraday.response :logger
  faraday.adapter Faraday.default_adapter  # make requests with Net::HTTP
  faraday.basic_auth($config['api_token'], $config['api_secret'])
  faraday.headers['Accept'] = 'application/json'
end


$domain_path = "/partners/#{URI.escape($config['partner'])}/domains/#{URI.escape($config['domain'])}"
$context_path = "/partners/#{URI.escape($config['partner'])}/contexts/#{URI.escape($config['context'])}"

Bandwidth::Client.global_options = {:user_id => $config['catapult_user_id'], :api_token => $config['catapult_api_token'], :api_secret => $config['catapult_api_secret']}

#db connection
$db = SQLite3::Database.new(ENV['DATABASE'] || './acmedb.sqlite')

#creating database structure
def create_database_if_need()
  sql =  <<-SQL
    create table if not exists "users" ("id" integer not null primary key autoincrement, "userName" varchar(255) not null,  "phoneNumber" varchar(255) not null, "password" varchar(255) not null, "extensionId" varchar(255) not null, "sipUri" varchar(255) not null, "uuid" varchar(255) not null,  "_tokens" text);
    create unique index if not exists users_username_unique on "users" ("userName");
    create unique index if not exists users_uuid_unique on "users" ("uuid");
    create unique index if not exists users_sipuri_unique on "users" ("sipUri");
    create unique index if not exists users_phonenumber_unique on "users" ("phoneNumber");
  SQL
  sql.split("\n").each do |command|
    $db.execute command
  end
end

#perform http request to MMP
def make_mmp_request(method, path, data = {})
  response =  if method == :get || method == :delete
    $mmp.run_request(method, path, nil, nil) do |req|
      req.params = data unless data == nil || data.empty?
    end
    else
      $mmp.run_request(method, path, data.to_json(), {'Content-Type' => 'application/json'})
    end
  check_response(response)
  begin
    if response.headers['content-type'] == 'application/json'
      then JSON.parse(response.body)
    else
      response.body
    end
  rescue
    response.body
  end
end

def check_response(response)
  if response.status >= 400
    raise Exception.new(response.body)
  end
end


#check if user nae is free to use
def check_if_user_name_is_available(user_name)
  r = $mmp.get "#{$domain_path}/users/#{URI.escape(user_name)}"
  if r.status != 404
    raise ArgumentError.new("User name #{user_name} is busy")
  end
end

#create mmp domain
def create_mmp_domain_if_need()
  r = $mmp.get $domain_path
  if r.status == 404
    return make_mmp_request :post, "/partners/#{URI.escape($config['partner'])}/domains", {
      'name' => $config['domain'],
      'addressUriScheme' => 'tel',
      'httpServiceProvider' => {
        'description' => $config['domain'],
        'uri' => $config['base_url'] + '/mmp',
        'username' => 'admin',
        'password' => 'admin'
      }
    }
  end
  raise r.text if r.status >= 400
end

#create mmp context
def create_mmp_context_if_need()
  r = $mmp.get $context_path
  if r.status == 404
    return make_mmp_request :post, "/partners/#{URI.escape($config['partner'])}/contexts", {
      'name' => $config['context'],
      'addressUriScheme' => 'tel',
      'httpServiceProvider' => {
        'description' => $config['domain'],
        'uri' => $config['base_url'] + '/mmp',
        'username' => 'admin',
        'password' => 'admin'
      }
    }
  end
  raise r.text if r.status >= 400
end

# LOGS
enable :logging, :dump_errors, :raise_errors

before do
    puts 'Request params'
    p params
end

after do
  puts "Response body"
  p response.body
end


# ROUTES

set :bind, '0.0.0.0'
set :port, ENV['PORT'] || 3000

# POST /users
post '/users' do
  content_type :json
  begin
    raise "Missing userName" unless params['userName']
    raise "userName should be at least 2 symbols" unless params['userName'].length >= 2
    check_if_user_name_is_available params['userName']
    user = $db.execute('select id from users where userName=? limit 1', [params['userName']]).first
    raise "User with name #{params['userName']} is exists already" if user
    user_path = "/users/#{URI.escape(params['userName'])}"

    #reserving a phone number
    numbers = Bandwidth::AvailableNumber.search_local(:state => 'NC', :quantity => 1)
    phone_number = numbers[0][:number]
    Bandwidth::PhoneNumber.create(:number => phone_number, :application_id => $application_id)

    #creating an user on MMP
    make_mmp_request :post, "#{$domain_path}/users", {:name => params['userName']}

    #creating an extension with phone number
    make_mmp_request :post, "#{$context_path}/extensions", {:name => phone_number}

    #making a link the user with the extension
    make_mmp_request :put, "#{$context_path}/extensions/#{URI.escape(phone_number)}/users", {'userUris' => "#{$config['base_mmp_url']}#{$domain_path}#{user_path}"}

    # geting tokens
    token_links = make_mmp_request(:get, "#{$domain_path}#{user_path}/apiTokens")
    tokens = token_links.map {|t| make_mmp_request(:get, t['link'])}

    # get user's data
    u = make_mmp_request(:get, "#{$domain_path}#{user_path}")
    password = (0...16).map { ('a'..'z').to_a[rand(26)] }.join

    # create endpoint (for SIP calls)
    endpoint = $domain.create_endpoint({
      :name => params['userName'],
      :domain_id => $domain.id,
      :application_id => $application_id,
      :enabled => true,
      :credentials => {
        :password => password
      }
    })
    mmp = Faraday.new(:url => $config['base_mmp_url']) do |faraday|
      faraday.response :logger
      faraday.adapter Faraday.default_adapter
      faraday.basic_auth(tokens.first['token'], tokens.first['secret'])
      faraday.headers['Accept'] = 'application/json'
    end
    # get extension id
    r = mmp.get "/users/#{URI.escape(u['uuid'])}/extensions"
    link = JSON.parse(r.body).first['link']
    extension_id = link.split('/').last

    # save to db
    $db.execute("insert into users(userName, phoneNumber, password, sipUri, extensionId, uuid, _tokens) values(?,?,?,?,?,?,?)", [
      params['userName'],
      phone_number,
      password,
      endpoint[:sip_uri],
      extension_id,
      u['uuid'],
      tokens.to_json()
    ])
    #return json
    {
      'userName' => params['userName'],
      'phoneNumber' => phone_number,
      'password' => password,
      'sipUri' => endpoint[:sip_uri],
      'uuid' => u['uuid'],
      'tokens' => tokens,
      'extensionId' => extension_id,
      'partner' => $config['partner'],
      'baseMmpUrl' => $config['base_mmp_url'],
      'mmpWebsocketUrl' => $config['mmp_websocket_url']
    }.to_json
  rescue =>e
    status 400
    {'result' => 'error', 'message' => e.to_s}.to_json
  end
end

get '/users' do
  records = $db.execute('select userName, uuid, _tokens, phoneNumber, sipUri, extensionId, password from users')
  users = records.map {|r| {:user_name => r[0], :uuid => r[1], :tokens => JSON.parse(r[2]), :phone_number => r[3], :sip_uri => r[4], :extension_id => r[5], :password => r[6]}}
  haml :users, :locals => {:users => users}
end

get '/' do
  redirect '/users'
end

# handle call events from Catapult
post '/call' do
  case params['eventType']
    when 'incomingcall'
      callback_url = "#{$config['base_url']}/call"
      user = $db.execute('select phoneNumber, sipUri from users where phoneNumber = ?', [params['to']]).first
      if user
        #incoming call
        p "Incoming call from #{params['from']} to #{params['to']}"
        Bandwidth::Call.create({:from => user[0], :to => user[1], :callback_url => callback_url, :tag => params['callId']})
        return ''
      end
      user = $db.execute('select phoneNumber from users where sipUri = ?', [params['from']]).first
      if user
        #outgoing call
        p "Outgoing call from #{user[0]} to #{params['to']}"
        Bandwidth::Call.create({:from => user[0], :to => params['to'], :callback_url => callback_url, :tag => params['callId']})
      end
    when 'answer'
     return '' unless params['tag']
     call = Bandwidth::Call.get(params['tag'])
     return '' if (call.to_data())[:bridge_id]
     call.answer_on_incoming() unless call.state == 'active'
     Bandwidth::Bridge.create({:call_ids => [params['tag'], params['callId']], :bridge_audio => true})
  end
  ''
end

# handle messages events from Catapult
post '/message' do
  if params['direction'] == 'in'
    begin
    json = {
      'from' => "tel:#{params['from']}",
      'to' => ["tel:#{params['to']}"],
      'text' => params['text']
    }.to_json

    mmp = Faraday.new(:url => $config['base_mmp_url']) do |faraday|
      faraday.response :logger
      faraday.adapter Faraday.default_adapter  # make requests with Net::HTTP
      faraday.basic_auth($service_provider_token, $service_provider_secret)
    end
    mmp.run_request(:post, '/serviceProviders/messages', json, {'Content-Type' => 'application/json'})
    rescue Exception => err
      puts err
    end
  end
  ''
end


# handle messages from MMP
post '/mmp' do
  begin
    message = params['message']
    return '' unless message
    p message
    from_number = message['from'][4..-1]
    messages = message['to'].map do |to|
      {:from => from_number, :to => to[4..-1], :text => message['text']}
    end
    Bandwidth::Message.create messages
  rescue Exception => err
    puts err
  end
  ''
end

create_database_if_need()
create_mmp_domain_if_need()
create_mmp_context_if_need()
$domain = (Bandwidth::Domain.list().select {|d| d.name == $config['domain']}).first || Bandwidth::Domain.create({
  :name => $config['domain']
})
$application_id = ((Bandwidth::Application.list().select {|a| a.name == $application_name }).first || Bandwidth::Application.create({
  :name => $application_name,
  :incoming_call_url => $config['base_url'] + '/call',
  :incoming_message_url =>  $config['base_url'] + '/message',
  :auto_answer => false
})).id
link = make_mmp_request(:get, "#{$context_path}/serviceProvider/apiTokens").first['link']
res = make_mmp_request(:get, link)
$service_provider_token = res['token']
$service_provider_secret = res['secret']
