vcl 4.0;

import std;
import directors;

backend server1 { # 定义一个backend
  .host = "";    # IP or Hostname of backend
  .port = "";           # Port Apache or whatever is listening
  #.max_connections = 300; # That's it

  .probe = {
    #.url = "/"; # short easy way (GET /)
    # We prefer to only do a HEAD /
    .request =
      "HEAD / HTTP/1.1"
      "Host: localhost"
      "Connection: close"
      "User-Agent: Varnish Health Probe";

    .interval  = 5s; # 多长时间检测web服务器是否正常运行
    .timeout   = 1s; # timing out after 1 second.
    .window    = 5;  # 如果最后5个请求中的三个是成功的，则被认为正常，否则认为服务器挂掉
    .threshold = 3;
  }

  .first_byte_timeout     = 20s;   # 在从后端接收第一个字节之前要等待多长时间?
  .connect_timeout        = 20s;     # 等待后端连接多长时间?
  .between_bytes_timeout  = 20s;     # 从后端接收的字节之间要等待多长时间?
}

acl purge {
  # ACL允许被清楚缓存的地址（默认本机）
  "localhost";
  "127.0.0.1";
  "::1";
}

sub vcl_init {
  # 缓存服务器配置（多个继续添加）

  new vdir = directors.round_robin();
  vdir.add_backend(server1);
  # vdir.add_backend(server2);
  # vdir.add_backend(servern);
}

sub vcl_recv {
  # 在接收和解析完请求之后，在请求开始时调用。作用是如何处理收到的请求（四种方式）。

  set req.backend_hint = vdir.backend(); # 所有请求都发送到vdir

  # 规范化消息头，删除端口(以防您在各种TCP端口上测试这个端口)
  # set req.http.Host = regsub(req.http.Host, ":[0-9]+", "");

  # 删除代理头 (see https://httpoxy.org/#mitigate-varnish)
  # unset req.http.proxy;

  # 规范化的查询参数
  set req.url = std.querysort(req.url);

  # 允许清除缓存
  if (req.method == "PURGE") {
    if (!client.ip ~ purge) {
      # 不是从一个允许的IP?返回没有权限。
      return (synth(405, "This IP is not allowed to send PURGE requests."));
    }
    return (purge);
  }

  # 哪些请求直接走管道（即不缓存），"GET"，"HEAD"，"PUT"，"POST"，"TRACE"，"OPTIONS"，"PATCH"，"DELETE"。
  #if (req.method != "GET" && req.method != "HEAD") {
  #  return (pipe);
  #}

  # 哪些请求走PASS，确保POST请求pass。
  if (req.method != "GET" && req.method != "HEAD") {
    return (pass);
  }

  # websocket支持 (https://www.varnish-cache.org/docs/4.0/users-guide/vcl-example-websockets.html)
  #if (req.http.Upgrade ~ "(?i)websocket") {
  #  return (pipe);
  #}

  # regsub(str,regex,sub)和regsuball(str,regex,sub):这两个用于基于正则表达式搜索指定的字符串并将其替换为指定的字符串；但regsuball()
  # 可以将str中能够被regex匹配到的字符串统统替换为sub，regsub()只替换一次；
  #if (req.url ~ "(\?|&)(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=") {
  #  set req.url = regsuball(req.url, "&(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "");
  #  set req.url = regsuball(req.url, "\?(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "?");
  #  set req.url = regsub(req.url, "\?&", "?");
  #  set req.url = regsub(req.url, "\?$", "");
  #}

  # 一些通用的cookie操作，适用于所有遵循的模板。
  #set req.http.Cookie = regsuball(req.http.Cookie, "has_js=[^;]+(; )?", "");
  #set req.http.Cookie = regsuball(req.http.Cookie, "__utm.=[^;]+(; )?", "");
  #set req.http.Cookie = regsuball(req.http.Cookie, "_ga=[^;]+(; )?", "");
  #set req.http.Cookie = regsuball(req.http.Cookie, "_gat=[^;]+(; )?", "");
  #set req.http.Cookie = regsuball(req.http.Cookie, "utmctr=[^;]+(; )?", "");
  #set req.http.Cookie = regsuball(req.http.Cookie, "utmcmd.=[^;]+(; )?", "");
  #set req.http.Cookie = regsuball(req.http.Cookie, "utmccn.=[^;]+(; )?", "");

  # no-cahce操作，no-cache请求，不缓存。
  #if (req.http.Cache-Control ~ "(?i)no-cache") {
  #  if (client.ip ~ purge) {
  #    if (! (req.http.Via || req.http.User-Agent ~ "(?i)bot" || req.http.X-Purge)) {
  #      return(purge);
  #    }
  #  }
  #}

  # 大的静态文件直接delivered到客户端，无需等待Varnish充分读取。
  # Varnish 4 fully supports Streaming, so set do_stream in vcl_backend_response()
  if (req.url ~ "^[^?]*\.(7z|avi|bz2|flac|flv|gz|mka|mkv|mov|mp3|mp4|mpeg|mpg|ogg|ogm|opus|rar|tar|tgz|tbz|txz|wav|webm|xz|zip)(\?.*)?$") {
    unset req.http.Cookie;
    return (hash);
  }

  # 删除所有用于静态文件的cookie。
  # 讨论是否需要缓存这些资源。
  if (req.url ~ "^[^?]*\.(7z|bz2|eot|flac|gz|ico|js|less|mka|mkv|mp4|odt|otf|ogg|ogm|opus|rtf|svg|svgz|tar|tbz|tgz|ttf|txz|webm|webp|woff|woff2|xml|xz|rar|zip|pdf|doc|docx|xls|xlsx|ppt|pptx|chm|hlp|swf|gif|jpg|jpeg|png|rm|flv|wmv|asf|mov|mpg|mpeg|avi|mp3|wav|mid|midi|ra|wma|gif|bmp|txt|css|csv)(\?.*)?$") {
    unset req.http.Cookie;
    return (hash);
  }

  # 发送代理功能头，告知ESI支持后端。
  #set req.http.Surrogate-Capability = "key=ESI/1.0";

  # 默认不缓存
  #if (req.http.Authorization) {
  #  return (pass);
  #}

  return (hash);
}

sub vcl_pipe {
  # 进入管道模式
  # 在此状态下也会进入后端获取内容，但与Pass不同，Varnish会在服务端和请求端之间建立一条直接的连接，绕过Varnish，此时Varnish相当于代理服务器

  # set bereq.http.Connection = "Close";

  # 实现websocket支持 (https://www.varnish-cache.org/docs/4.0/users-guide/vcl-example-websockets.html)
  #if (req.http.upgrade) {
  #  set bereq.http.upgrade = req.http.upgrade;
  #}

  #return (pipe);
}

sub vcl_pass {
  # 在此状态下会进入后端获取内容，既进入Fetch状态；

  # return (pass);
}

# The data on which the hashing will take place
sub vcl_hash {
  # 调用vcl_recv来为请求创建一个散列值。用来作为查找Varnish中的对象的钥匙。

  hash_data(req.url);

  if (req.http.host) {
    hash_data(req.http.host);
  } else {
    hash_data(server.ip);
  }

  if (req.http.Cookie) {
    hash_data(req.http.Cookie);
  }
}

sub vcl_hit {
  # 当缓存查找成功时调用。

  if (obj.ttl >= 0s) {
    return (deliver);
  }

  # 当多个用户同时请求一个页面时，Varnish只发送一个请求到服务器，其他请求待命，直到请求之后，其他请求取同一个副本。这个是Varnish自带机制。
  # 如果每秒钟请求服务数千次，那么等待请求的队列就会变得非常大。有两个潜在的问题：首先，突然释放上千个线程导致服务器负载过高。其次，没有人喜欢等待。为了处理这个问题，
  # 我们可以指导Varnish将对象保存在它们的TTL之外，并为等待的请求提供一些陈旧的内容。

# if (!std.healthy(req.backend_hint) && (obj.ttl + obj.grace > 0s)) {
#   return (deliver);
# } else {
#   return (miss);
# }

  # 请求过多时
  if (std.healthy(req.backend_hint)) {
    if (obj.ttl + 10s > 0s) {
      return (deliver);
    } else {
      return(miss);
    }
  } else {
      if (obj.ttl + obj.grace > 0s) {
      return (deliver);
    } else {
      return (miss);
    }
  }

  return (miss);
}

sub vcl_miss {
  # 如果在缓存中未找到所请求的文档，则调用缓存查找。其目的是决定是否尝试从后端检索文档，以及使用哪个后端。

  return (fetch);
}

# 从后台服务器取回数据后,视情况是否进行缓存
sub vcl_backend_response {
  # 在从后端成功检索响应头之后调用。

  # 暂停ESI请求并清除Surrogate-Control头
  #if (beresp.http.Surrogate-Control ~ "ESI/1.0") {
  #  unset beresp.http.Surrogate-Control;
  #  set beresp.do_esi = true;
  #}

  # 为所有静态文件启用缓存。
  # 与上面的静态缓存相同的参数是:监控缓存大小，如果数据被删除，考虑放弃静态文件缓存。
  if (bereq.url ~ "^[^?]*\.(7z|bz2|eot|flac|gz|ico|js|less|mka|mkv|mp4|odt|otf|ogg|ogm|opus|rtf|svg|svgz|tar|tbz|tgz|ttf|txz|webm|webp|woff|woff2|xml|xz|rar|zip|pdf|doc|docx|xls|xlsx|ppt|pptx|chm|hlp|swf|gif|jpg|jpeg|png|rm|flv|wmv|asf|mov|mpg|mpeg|avi|mp3|wav|mid|midi|ra|wma|gif|bmp|txt|css|csv)(\?.*)?$") {
    unset beresp.http.set-cookie;
    set beresp.ttl = 20d;
    return (deliver);
  }

  # 大型静态文件直接交付给终端用户
  if (bereq.url ~ "^[^?]*\.(7z|avi|bz2|flac|flv|gz|mka|mkv|mov|mp3|mp4|mpeg|mpg|ogg|ogm|opus|rar|tar|tgz|tbz|txz|wav|webm|xz|zip)(\?.*)?$") {
    unset beresp.http.set-cookie;
    ## 检查内存使用情况，如果后端不发送Content-Length头，它将在fetch_chunksize块(默认为128k)中增长，因此只允许大型对象使用。
    set beresp.do_stream = true;
  }

  # 301/302重定向
  #if (beresp.status == 301 || beresp.status == 302) {
  #  set beresp.http.Location = regsub(beresp.http.Location, ":[0-9]+", "");
  #}

  # 如果未设置静态文件，则设置2min缓存。重要！！！！！！
  if (beresp.ttl <= 0s || beresp.http.Set-Cookie || beresp.http.Vary == "*") {
    set beresp.ttl = 120s;
    set beresp.uncacheable = true;
    return (deliver);
  }

  # 不缓存500响应
  if (beresp.status == 500 || beresp.status == 502 || beresp.status == 503 || beresp.status == 504) {
    return (abandon);
  }

  # 服务器死机，保持6小时读取缓存
  set beresp.grace = 6h;

  return (deliver);
}

# 客户端请求的最后一个流程
sub vcl_deliver {
  # 将缓存对象交付给客户端之前调用。

  if (obj.hits > 0) {
    set resp.http.X-Cache = "HIT";
  } else {
    set resp.http.X-Cache = "MISS";
  }

  set resp.http.X-Cache-Hits = obj.hits;

  # 清除某些HEADER（PHP）
  #unset resp.http.X-Powered-By;

  # 清除某些HEADER（Apache和OS）
  unset resp.http.Server;
  unset resp.http.X-Drupal-Cache;
  unset resp.http.X-Varnish;
  unset resp.http.Via;
  unset resp.http.Link;
  unset resp.http.X-Generator;

  return (deliver);
}

sub vcl_purge {
  # 只处清除HTTP方法，其他的都被丢弃。
  if (req.method != "PURGE") {
    # restart request
    set req.http.X-Purge = "Yes";
    return(restart);
  }
}

#301/302重定向处理
sub vcl_synth {
  if (resp.status == 720) {
    # 使用这个特殊的错误状态720来强制重定向301(永久)重定向。
    set resp.http.Location = resp.reason;
    set resp.status = 301;
    return (deliver);
  } elseif (resp.status == 721) {
    # 我们使用错误状态721强制重定向使用302(临时)重定向。
    set resp.http.Location = resp.reason;
    set resp.status = 302;
    return (deliver);
  }

  return (deliver);
}


sub vcl_fini {
  # 当VCL在所有请求都退出VCL后才被丢弃。通常被用于清除VMODs。

  return (ok);
}
