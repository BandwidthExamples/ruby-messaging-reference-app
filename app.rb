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
    create table if not exists "users" ("id" integer not null primary key autoincrement, "userName" varchar(255) not null,  "phoneNumber" varchar(255) not null, "uuid" varchar(255) not null,  "_tokens" text);
    create unique index if not exists users_username_unique on "users" ("userName");
    create unique index if not exists users_uuid_unique on "users" ("uuid");
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
    Bandwidth::PhoneNumber.create(:number => phone_number)

    #creating an user on MMP
    make_mmp_request :post, "#{$domain_path}/users", {:name => params['userName']}

    #creating an extension with phone number
    make_mmp_request :post, "#{$context_path}/extensions", {:name => phone_number}

    #making a link the user with the extension
    make_mmp_request :put, "#{$context_path}/extensions/#{URI.escape(phone_number)}/users", {'userUris' => "#{$config['base_mmp_url']}#{$domain_path}#{user_path}"}

    # geting tokens and user's data
    token_links = make_mmp_request(:get, "#{$domain_path}#{user_path}/apiTokens")
    tokens = token_links.map {|t| make_mmp_request(:get, t['link'])}
    u = make_mmp_request(:get, "#{$domain_path}#{user_path}")
    $db.execute("insert into users(userName, phoneNumber,  uuid, _tokens) values(?,?,?,?)", [params['userName'], phone_number, u['uuid'], tokens.to_json()])
    #return json
    {'userName' => params['userName'], 'phoneNumber' => phone_number, 'uuid' => u['uuid'], 'tokens' => tokens}.to_json
  rescue =>e
    status 400
    {'result' => 'error', 'message' => e.to_s}.to_json
  end
end

get '/users' do
  records = $db.execute('select userName, uuid, _tokens, phoneNumber from users')
  users = records.map {|r| {:user_name => r[0], :uuid => r[1], :tokens => JSON.parse(r[2]), :phone_number => r[3]}}
  haml :users, :locals => {:users => users}
end

get '/' do
  redirect '/users'
end

create_database_if_need()
