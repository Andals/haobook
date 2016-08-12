.. _periodical-201608-zhangan:

跨域post
============

.. contents:: 目录

====================================
跨域（Cross-Orgin Resource Sharing）
====================================

所谓的跨域限制是存在浏览器中的，服务端间访问并没有这样的限制。

而就是因为浏览器有个跨域限制的行为，所以在介绍和解决跨域传输数据的问题之前需要先了解这个限制行为是什么，
目的是什么，之后，才能更好的解决问题。

关于跨域的第一个接触到的问题就是为什么会跨域，就是因为浏览器的 *同源策略*

===========================================================================================
同源策略（Same-origin policy， SOP）
===========================================================================================

-----
概念
-----

* 相同协议
* 相同域名
* 相同端口

举例来说 ``http://www.example.com/ctr/index.html`` 这个网址的

协议是 ``http`` , 

域名是 ``www.example.com`` ,
 
端口是 ``80`` （http默认端口）,那么下面例子进行对比说明同源的情况：

============================================================  =========  ========================
 用于比较的URL                                                是否同源      理由                   
============================================================  =========  ========================
 `http://www.example.com/dir/page2.html`                       是         同协议，同域名，同端  
 `http://www.example.com/dir2/other.html`	                   是         同协议，同域名，同端口
 `http://username:password@www.example.com/dir2/other.html`    是         同协议，同域名，同端口 
 `http://www.example.com:81/dir/other.html`	                   否         不同端口               
 `https://www.example.com/dir/other.html`	                   否         不同协议 
 `http://en.example.com/dir/other.html`	                       否         不同域名 
 `http://example.com/dir/other.html`	                       否         不同域名 
 `http://v2.www.example.com/dir/other.html`	                   否         不同域名 
============================================================  =========  ========================

------
目的
------

同源政策的目的，是为了保证用户信息的安全，防止恶意的网站窃取数据。

设想这样一种情况：A网站是一家银行，用户登录以后，又去浏览其他网站。

如果其他网站可以读取A网站的 Cookie，会发生什么？

很显然，如果 Cookie 包含隐私（比如存款总额），这些信息就会泄漏。更可怕的是，
Cookie 往往用来保存用户的登录状态，如果用户没有退出登录，其他网站就可以冒充用户，为所欲为。

由此可见，"同源政策"是必需的，否则 Cookie 可以共享，互联网就毫无安全可言了。

---------
限制范围
---------

1. Cookie、LocalStorage 和 IndexDB 无法读取。
#. DOM 无法获得。
#. AJAX 请求不能发送。

也正是因为这些安全策略的保护，让我们更安心上网，但是，同样限制了我们的一些需求，特别是针对开发人员。

也就是最近在开发中出现了这个问题，那么，下面就来说下关于 跨域post的解决办法。

不过，在真正贴出解决办法的代码之前，还需要了解一个定义 **预请求**

======================
简单的跨域请求和预请求
======================

--------------
简单的跨域请求
--------------

简单请求就是只

* 使用 GET,HEAD或者POST,而不使用自定义请求头（类似 X-Modified）

* 如果是POST，则请求的Content-Type应该为：application/x-www-form-urlencode, multipart/form-data, text/plain。

而只要是如上这些Content-Type，服务器的相应头里面的Access-Control-Allow-Orgin会被设置成为 * 。

就是可以访问其网站上的任意数据。

--------------------------
预请求
--------------------------

不同于简单请求，预请求需要先发送一个OPTIONS请求给目的站点，来预先访问该跨站点请求是否是安全可信任的。

当具备一下条件就会当成预请求处理：

* 请求以GET,HEAD或者POST以外的方式请求。再或者POST的数据类型非简单请求的数据类型，即非 application/x-www-form-urlencode,
  multipart/form-data， text/plain，比如说 application/json 或者 application/xml。

* 使用自定义请求头

预检请求发送的时候，最关键的就是header中的origin，举例来说：

::

    PTIONS /cors HTTP/1.1
    Origin: http://api.example.com
    Access-Control-Request-Method: PUT
    Access-Control-Request-Headers: X-Custom-Header
    Host: api.localhost.com
    Accept-Language: en-US
    Connection: keep-alive
    User-Agent: Mozilla/5.0...
    
该Origin表示来自哪个源。

预请求的回应也就是我们要针对跨域POST做的事情了。

==========================
针对跨域post的解决办法
==========================

先说解决办法，在http响应头中添加如下内容

::

	header('Access-Control-Allow-Credentials: true');
	header("Access-Control-Allow-Origin: $httpReferer");
	header('Access-Control-Allow-Methods:GET,POST,OPTIONS');

刚刚在header中添加的内容的解释：

* `Access-Control-Allow-Origin`
   该字段是必须的。它的值要么是请求时 ``Origin`` 字段的值，要么是一个*，表示接受任意域名的请求。
* `Access-Control-Allow-Credentials`
   该字段可选。它的值是一个布尔值，表示是否允许发送Cookie。
* `Access-Control-Allow-Methods`
   该字段是必须的，用来列出浏览器的CORS请求会用到哪些HTTP方法，上例是 ``PUT,POST,OPTIONS``


=================================
其他关于跨域POST请求的解决办法
=================================

1. **Server Proxy**

   当前域实现一个代理，所有向外部域名发送的请求都经由该代理中转。

#. **Flash Proxy**

   服务端部署跨域策略文件crossdomain.xml，页面利用不可见的swf跨域post提交数据实现跨域通信。

#. **Invisible Iframe**

   通过js动态生成不可见表单和iframe，将表单的target设为iframe的name以此通过iframe做post提交。



-----------
参考文章
-----------

* `HTTP访问控制 <https://developer.mozilla.org/zh-CN/docs/Web/HTTP/Access_control_CORS>`_
* `Cross-Origin Resource Sharing <https://www.w3.org/TR/cors/>`_
* `Same-origin policy <https://developer.mozilla.org/en-US/docs/Web/Security/Same-origin_policy>`_
