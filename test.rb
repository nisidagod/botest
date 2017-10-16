# coding: utf-8

require 'rest-client'
require 'json'
require 'date'
require 'gmail'
require 'yaml'
#google-api-clientはv0.6.4が必要です
require "google/api_client"

class MyMail
  #GMail関連の設定
  ID = "GMail address"
  PW = "GMail password"
  TO = "mail send to address"

  def self.send(sbj,msg)
    gmail = Gmail.new(ID, PW)

    message =
      gmail.generate_message do
        to TO
        subject sbj
        body msg
      end

    gmail.deliver(message)
    gmail.logout
  end
end

class LineBot
  #LINE関連の設定
  TOKEN  = "Channel Access Token"
  TO     = "送信先のID"

  def self.send(msg)
    headers = {
      "Content-Type"  => "application/json; charser=UTF-8",
      "Authorization" => "Bearer #{TOKEN}",
    }

    params = {
      to: TO,
      messages: [
        {
          type: "text",
          text: msg,
        }
      ]
    }

    RestClient.post "https://api.line.me/v2/bot/message/push", params.to_json, headers
  end
end

class GCal
  def initialize(list)
    @g_list = list

    yaml_path = File.expand_path(".google-api.yaml",File.dirname(__FILE__))
    oauth = YAML.load_file(yaml_path)

    @client = Google::APIClient.new({:application_name => "line_bot_gcal",:application_version => "1.0"})
    @client.authorization.client_id     = oauth["client_id"]
    @client.authorization.client_secret = oauth["client_secret"]
    @client.authorization.scope         = oauth["scope"]
    @client.authorization.refresh_token = oauth["refresh_token"]
    @client.authorization.access_token  = oauth["access_token"]
    if @client.authorization.refresh_token && @client.authorization.expired?
      @client.authorization.fetch_access_token!
    end

    @service = @client.discovered_api('calendar', 'v3')
  end

  def get_gids
    gcal_list = @client.execute(:api_method => @service.calendar_list.list)

    gcal_ids = []
    gcal_list.data.items.each do |c|
      gcal_ids.push [c["summary"],c["id"]] if @g_list.include? c["summary"]
    end
    gcal_ids
  end

  def get_event(day)
    @day = day
    gcal_ids = get_gids

    params = {}
    params['timeMin'] = Time.utc(day.year, day.month, day.day, 0).iso8601
    params['timeMax'] = Time.utc(day.year, day.month, day.day, 23, 59, 60).iso8601

    @event = {}
    gcal_ids.each do |gcal|
      params['calendarId'] = gcal[1]
      params.delete("pageToken") unless params["pageToken"].nil?

      events = @client.execute(:api_method => @service.events.list,:parameters => params)
      while true
        events.data.items.each do |e|
          @event[gcal[0]] = [] if @event[gcal[0]].nil?
          @event[gcal[0]].push e
        end
        break if !(page_token = events.data.next_page_token)
        params["pageToken"] = page_token
        events = @client.execute(:api_method => @service.events.list,:parameters => params)
      end
    end
  end

  def make_msg
    d = {}
    d[:at]   = {}
    d[:from] = {}
    d[:to]   = {}

    day  = @day.strftime("%Y-%m-%d")
    nday = (@day + 1).strftime("%Y-%m-%d")
    @event.each do |k,v|
      conf = []
      canc = []
      v.each do |e|
        if e.status == "cancelled"
          canc.push(e.recurringEventId)
        else
          conf.push(e.id)
        end
      end
      ok = conf - canc
      v.each do |e|
        next if e.status == "cancelled"
        next unless ok.include? e.id
        if e.start.date.nil?
          if e.recurrence.size == 0
            next unless e.start.date_time.strftime("%Y-%m-%d") == day
          end
          d[:at][k] = [] if d[:at][k].nil?
          msg = e.start.date_time.strftime("%H:%M")
          msg = msg + " - "
          if e.recurrence.size == 0
            msg = msg + e.end.date_time.strftime("%m/%d ") unless e.end.date_time.strftime("%Y-%m-%d") == day
          end
          msg = msg + e.end.date_time.strftime("%H:%M")
          msg = msg + " " + e.summary
          d[:at][k].push msg
        else
          type = nil
          case
          when ((e.start.date == day) and (e.end.date == nday))
            type = :at
          when e.start.date == day
            type = :from
          when e.end.date == nday
            type = :to
          end
          next if type.nil?
          d[type][k] = [] if d[type][k].nil?
          d[type][k].push e.summary
        end
      end
    end
    ret = nil
    s = {:at => "",:from => "から",:to => "まで"}
    ["at" , "from" , "to"].each do |t|
      t = t.to_sym
      unless d[t].size == 0
        ret = ret.nil? ? "" : ret + "\n"
        ret = ret + day + s[t] + "の予定"
        d[t].each do |k,v|
          ret = ret + "\n [" + k + "]"
          v.sort.each do |e|
            ret = ret + "\n  " + e
          end
        end
      end
    end
    ret
  end
end


#送信したいカレンダー名を列挙する
GCAL_LIST = [
             "お仕事",
             "記念日",
             "遊び",
            ]

g = GCal.new(GCAL_LIST)
tmr = Date.today + 1
g.get_event(tmr)
msg = g.make_msg

unless msg.nil?
  begin
    LineBot.send(msg)
  rescue => e
    print "#{Time.now.to_s} line bot error raise!\n"
    MyMail.send "line bot error raise",e.response
    exit
  end
  print "#{Time.now.to_s} send event!\n"
else
  print "#{Time.now.to_s} no event.\n"
end
