<div align="center">

# Bandwidth Ruby Messaging Reference App

<a href="http://dev.bandwidth.com"><img src="https://s3.amazonaws.com/bwdemos/BW_Messaging.png"/></a>
</div>

[![Deploy](https://www.herokucdn.com/deploy/button.svg)](https://heroku.com/deploy)

## Install
Before run it fill config file (config.yml) with right values:

`api_token` and `api_secret` - auth data for MMP requests to create an user, an extension, etc,

`partner`, `domain`, `context` - values of MMP path where new user and its data will be created (account with given `api_token` and `api_secret` should have permissions to work with this partner, this domain and this context),

`base_mmp_url` - base url for MMP requests,

`mmp_websocket_url` - url for websocket connections (to receive incoming messages) 

`catapult_user_id`, `catapult_api_token`, `catapult_api_secret` - auth data for Catapult API (to search and reserve a phone number, etc)

`base_url` - base url of this app.

After that run `bundler install` to install dependencies.


You can run this demo as `ruby app.rb` on local machine if you have ability to handle external requests or use any external hosting.

## Deploy on Heroku

Create account on [Heroku](https://www.heroku.com/) and install [Heroku Toolbel](https://devcenter.heroku.com/articles/getting-started-with-ruby#set-up) if need.

Open `config.yml` and fill it with valid values (except `base_url`).

Commit your changes.

```
git add .
git commit -a -m "Deployment"
```

Run `heroku create` to create new app on Heroku and link it with current project.

Change option `base_url` in `config.yml` by assigned by Heroku value (something like http://XXXX-XXXXX-XXXX.heroku.com). Commit your changes by `git commit -a`. 

Run `git push heroku master` to deploy this project.

Run `heroku open` to see home page of the app in the browser

## Http routes

```
GET / with redirect to /users
GET /users with HTML response (user's ui)
POST /users {"userName": "" }  with response  {"userName": "", "phoneNumber": "", "uuid": "", "tokens": [{"token": "", "secret": "", "createdAt": ""}]}  to register an user
``
