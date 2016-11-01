#coding: utf-8
# SMSC.RU API (smsc.ru) версия 1.3 (05.03.2015)

require "net/http"
require "net/https"
require "net/smtp"
require "uri"
require "erb"

class SMSC
  # Константы для настройки библиотеки
  SMSC_LOGIN = CASino.config.sms[:login] # логин клиента
  SMSC_PASSWORD = CASino.config.sms[:password] # пароль или MD5-хеш пароля в нижнем регистре
  SMSC_POST = true # использовать метод POST
  SMSC_HTTPS = true # использовать HTTPS протокол
  SMSC_CHARSET = "utf-8" # кодировка сообщения: koi8-r или windows-1251 (по умолчанию utf-8)
  SMSC_DEBUG = false # флаг отладки
  SMTP_FROM = "api@smsc.ru" # e-mail адрес отправителя

  # Функция отправки SMS
  #
  # обязательные параметры:
  #
  # phones - список телефонов через запятую или точку с запятой
  # message - отправляемое сообщение
  #
  # необязательные параметры:
  #
  # translit - переводить или нет в транслит (1,2 или 0)
  # time - необходимое время доставки в виде строки (DDMMYYhhmm, h1-h2, 0ts, +m)
  # id - идентификатор сообщения. Представляет собой 32-битное число в диапазоне от 1 до 2147483647.
  # format - формат сообщения (0 - обычное sms, 1 - flash-sms, 2 - wap-push, 3 - hlr, 4 - bin, 5 - bin-hex, 6 - ping-sms, 7 - mms, 8 - mail, 9 - call)
  # sender - имя отправителя (Sender ID). Для отключения Sender ID по умолчанию необходимо в качестве имени
  # передать пустую строку или точку.
  # query - строка дополнительных параметров, добавляемая в URL-запрос ("valid=01:00&maxsms=3&tz=2")
  #
  # возвращает массив (<id>, <количество sms>, <стоимость>, <баланс>) в случае успешной отправки
  # либо массив (<id>, -<код ошибки>) в случае ошибки

  def send_sms(phones, message, translit = 0, time = 0, id = 0, format = 0, sender = false, query = "")
    formats = ["flash=1", "push=1", "hlr=1", "bin=1", "bin=2", "ping=1", "mms=1", "mail=1", "call=1"]

    m = _smsc_send_cmd("send", "cost=3&phones=" + _urlencode(phones) + "&mes=" + _urlencode(message) +
        "&translit=#{translit}&id=#{id}" + (format > 0 ? "&#{formats[format-1]}" : "") +
        (sender == false ? "" : "&sender=" + _urlencode(sender)) +
        (time ? "&time=" + _urlencode(time) : "") + (query ? "&#{query}" : ""))

    # (id, cnt, cost, balance) или (id, -error)

    if SMSC_DEBUG
      if m[1] > "0"
        puts "Сообщение отправлено успешно. ID: #{m[0]}, всего SMS: #{m[1]}, стоимость: #{m[2]}, баланс: #{m[3]}\n"
      else
        puts "Ошибка №#{m[1][1]}" + (m[0] > "0" ? ", ID: #{m[0]}" : "") + "\n";
      end
    end

    return m
  end

  # SMTP версия функции отправки SMS

  def send_sms_mail(phones, message, translit = 0, time = 0, id = 0, format = 0, sender = "")
    $VERBOSE = nil

    Net::SMTP.start("send.smsc.ru") do |smtp|
      smtp.send_message("Content-Type: text/plain; charset=#{SMSC_CHARSET}\n\n#{SMSC_LOGIN}:#{SMSC_PASSWORD}:#{id}:#{time}:#{translit},#{format},#{sender}:#{phones}:#{message}", SMTP_FROM, "send@send.smsc.ru")
    end

    $VERBOSE = true
  end

  # Функция получения стоимости SMS
  #
  # обязательные параметры:
  #
  # phones - список телефонов через запятую или точку с запятой
  # message - отправляемое сообщение
  #
  # необязательные параметры:
  #
  # translit - переводить или нет в транслит (1,2 или 0)
  # format - формат сообщения (0 - обычное sms, 1 - flash-sms, 2 - wap-push, 3 - hlr, 4 - bin, 5 - bin-hex, 6 - ping-sms, 7 - mms, 8 - mail, 9 - call)
  # sender - имя отправителя (Sender ID)
  # query - строка дополнительных параметров, добавляемая в URL-запрос ("list=79999999999:Ваш пароль: 123\n78888888888:Ваш пароль: 456")
  #
  # возвращает массив (<стоимость>, <количество sms>) либо массив (0, -<код ошибки>) в случае ошибки

  def get_sms_cost(phones, message, translit = 0, format = 0, sender = false, query = "")
    formats = ["flash=1", "push=1", "hlr=1", "bin=1", "bin=2", "ping=1", "mms=1", "mail=1", "call=1"]

    m = _smsc_send_cmd("send", "cost=1&phones=" + _urlencode(phones) + "&mes=" + _urlencode(message) +
        "&translit=#{translit}" + (format > 0 ? "&#{formats[format-1]}" : "") +
        (sender == false ? "" : "&sender=" + _urlencode(sender)) +
        (query ? "&#{query}" : ""))

    # (cost, cnt) или (0, -error)

    if SMSC_DEBUG
      if m[1] > "0"
        puts "Стоимость рассылки: #{m[0]}. Всего SMS: #{m[1]}\n"
      else
        puts "Ошибка №#{m[1][1]}\n"
      end
    end

    return m
  end

  # Функция проверки статуса отправленного SMS или HLR-запроса
  #
  # id - ID cообщения
  # phone - номер телефона
  #
  # возвращает массив:
  # для отправленного SMS (<статус>, <время изменения>, <код ошибки sms>)
  # для HLR-запроса (<статус>, <время изменения>, <код ошибки sms>, <код IMSI SIM-карты>, <номер сервис-центра>,
  # <код страны регистрации>, <код оператора абонента>, <название страны регистрации>, <название оператора абонента>,
  # <название роуминговой страны>, <название роумингового оператора>)
  #
  # При all = 1 дополнительно возвращаются элементы в конце массива:
  # (<время отправки>, <номер телефона>, <стоимость>, <sender id>, <название статуса>, <текст сообщения>)
  #
  # либо массив (0, -<код ошибки>) в случае ошибки

  def get_status(id, phone, all = 0)
    m = _smsc_send_cmd("status", "phone=" + _urlencode(phone) + "&id=#{id}&all=#{all}")

    # (status, time, err, ...) или (0, -error)

    if SMSC_DEBUG
      if m[1] != "" && m[1] >= "0"
        puts "Статус SMS = #{m[0]}" + (m[1] > "0" ? ", время изменения статуса - " + Time.at(m[1].to_i).strftime("%d.%m.%Y %T") : "") + "\n"
      else
        puts "Ошибка №#{m[1][1]}\n"
      end
    end

    if all && m.size > 9 && ((defined?(m[14])).nil? || m[14] != "HLR")
      m = (m.join(",")).split(",", 9)
    end

    return m
  end

  # Функция получения баланса
  #
  # без параметров
  #
  # возвращает баланс в виде строки или false в случае ошибки

  def get_balance
    m = _smsc_send_cmd("balance") # (balance) или (0, -error)

    if SMSC_DEBUG
      if m.length < 2
        puts "Сумма на счете: #{m[0]}\n"
      else
        puts "Ошибка №#{m[1][1]}\n"
      end
    end

    return m.length < 2 ? m[0] : false
  end

  # ВНУТРЕННИЕ ФУНКЦИИ

  # Функция вызова запроса. Формирует URL и делает 3 попытки чтения

  def _smsc_send_cmd(cmd, arg = "")
    url = (SMSC_HTTPS ? "https" : "http") + "://smsc.ru/sys/#{cmd}" + ".php?login=" + _urlencode(SMSC_LOGIN) + "&psw=" + _urlencode(SMSC_PASSWORD) + "&fmt=1&charset=#{SMSC_CHARSET}&#{arg}"

    uri = URI.parse(url)
    http = _server_connect(uri)

    i = 0
    begin
      sleep(2 + i) if i

      if (i == 2)
        url.sub!("://smsc.ru/", "://www2.smsc.ru/")

        uri = URI.parse(url)
        http = _server_connect(uri)
      end

      begin
        r = (SMSC_POST || url.length > 2000) ? http.post2(uri.path, uri.query) : http.get2(uri.path + "?" + uri.query)
        ret = r.body
      rescue
        ret = ""
      end

      i+=1
    end until ret != "" || i == 4

    if ret == ""
      puts "Ошибка чтения адреса: #{url}\n" if SMSC_DEBUG

      ret = "0,0" # фиктивный ответ
    end

    return ret.split(",")
  end

  # Подключение к серверу

  def _server_connect(uri)
    http = Net::HTTP.new(uri.host, uri.port)

    if SMSC_HTTPS
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end

    return http
  end

  # кодирование параметра в http-запросе

  def _urlencode(str)
    ERB::Util.url_encode(str)
  end
end

# Examples:
# sms = SMSC.new()
#
# ret = sms.send_sms("79999999999", "Ваш пароль: 123", 1)
# ret = sms.send_sms("79999999999", "http://smsc.ru\nSMSC.RU", 0, 0, 0, 0, false, "maxsms=3")
# ret = sms.send_sms("79237476298", "0605040B8423F0DC0601AE02056A0045C60C036D79736974652E72750001036D7973697465000101", 0, 0, 0, 5)
# ret = sms.send_sms("79999999999", "", 0, 0, 0, 3)
# ret = sms.get_sms_cost("79999999999", "Вы успешно зарегистрированы!")
# sms.send_sms_mail("79999999999", "Ваш пароль: 123", 0, "0101121000")
# ret = sms.get_status(12345, "79999999999")
# balance = sms.get_balance