.. _periodical-201608-haoyankai

nginx filter模块实践
======================

.. contents:: 目录

背景
------
之前在做项目的时候，由于数据统计部门要追踪用户行为进行用户行为分析，所以要在nginx的log里加上一个标识用来追踪用户,当时考虑可以用nginx模块或者nginx lua来实现，因为nginx模块写起来时间比较长而且稳定性需要长时间验证所以当时用nginx lua实现了，然后现在就想尝试下用nginx模块的方式来写一下看看。

功能设计
--------
用户请求web服务，基于用户的访问时间，浏览器ua信息等等给用户生成一个唯一id，记录到nginx的变量里，然后可以加入到nginx的log_format中，记录到用户每条访问日志，然后把生成的唯一id传回给用户端浏览器，写入cookie，这样用户下次再来访问的话就用cookie中已经保存的唯一id计入log中。

`logid模块代码 <https://github.com/andals/ngx_logid/>`_

nginx模块简介
----------------------------------------
nginx的模块不像apache的模块一样，nginx的模块是静态编译的，也就是新安装一个模块的话需要重新编译并替换原来的nginx可执行文件。
nginx模块分为3类:

- handler 处理请求并生成内容输出给客户端

- filter 处理handler生成的内容

- load-balancer 选择后端的服务器发送请求

我们要讲的是filter模块，而filter模块又分为header filter和body filter，从名字上可以看出来header filter处理nginx response的header，body filter处理response的body。由于我们的logid模块需要处理response header去set cookie，所以是一个header filter。

功能实现
----------------------------------------
nginx为了做到不同操作系统的兼容，对底层数据操作做了一层封装，对外提供统一的接口，由nginx去实现不同操作系统需要的细节，函数命名规则一般为ngx_xxx。我们在编写模块的时候如果nginx提供了对应的函数，一定要使用nginx提供的函数，而不是使用原生的函数，不过要注意跟原生函数的使用方式可能会不一样。对于这些提供的函数使用前一定要查好文档，如果找不到太详细的文档可以去源码中看实现。

`nginx api文档 <https://www.nginx.com/resources/wiki/extending/api//>`_

基本数据结构
************

字符串
++++++++++++++
字符串是非常重要的数据结构，任何时候都离不开它，我们来看下nginx中的字符串是如何使用的。
先看下定义::

   typedef struct {
       size_t      len;
       u_char     *data;
   } ngx_str_t;

在C语言里，字符串一般都是以'\0'结尾，这种情况下如果数据本身含有'\0'的话就会有问题，比如压缩过的数据就可能含有'\0',所以nginx在char*的基础上做了封装，添加了len域，用来标识长度信息。
字符串常量的声明,注意只能::

        ngx_str_t logid = ngx_string("logid");

设置字符串操作，设置str为text，其中text必须为常量字符串::

        ngx_str_set(str, text)

不区分大小写的字符串比较，只比较前n个字符::

        ngx_strncmp(s1, s2, n)


还有经常会用到的字符串格式化函数::

        u_char * ngx_cdecl ngx_sprintf(u_char *buf, const char *fmt, ...);
        u_char * ngx_cdecl ngx_snprintf(u_char *buf, size_t max, const char *fmt, ...);
        u_char * ngx_cdecl ngx_slprintf(u_char *buf, u_char *last, const char *fmt, ...);

上边3个函数是对sprintf的封装，ngx_snprintf限制了格式化到buf的最大长度，ngx_slprintf使用尾指针来限制格式化的长度，需要特别注意的是fmt参数，跟原生的sprintf是不一样的::

        /*
         * supported formats:
         *    %[0][width][x][X]O        off_t
         *    %[0][width]T              time_t
         *    %[0][width][u][x|X]z      ssize_t/size_t
         *    %[0][width][u][x|X]d      int/u_int
         *    %[0][width][u][x|X]l      long
         *    %[0][width|m][u][x|X]i    ngx_int_t/ngx_uint_t
         *    %[0][width][u][x|X]D      int32_t/uint32_t
         *    %[0][width][u][x|X]L      int64_t/uint64_t
         *    %[0][width|m][u][x|X]A    ngx_atomic_int_t/ngx_atomic_uint_t
         *    %[0][width][.width]f      double, max valid number fits to %18.15f
         *    %P                        ngx_pid_t
         *    %M                        ngx_msec_t
         *    %r                        rlim_t
         *    %p                        void *
         *    %V                        ngx_str_t *
         *    %v                        ngx_variable_value_t *
         *    %s                        null-terminated string
         *    %*s                       length and string
         *    %Z                        '\0'
         *    %N                        '\n'
         *    %c                        char
         *    %%                        %
         *
         *  reserved:
         *    %t                        ptrdiff_t
         *    %S                        null-terminated wchar string
         *    %C                        wchar
         */


内存池
++++++++++++++
由于web server的特殊场景，内存分配与请求相关，一个请求过来，分配需要使用的内存，请求结束后这些所有内存都可以释放掉，所以每个请求结构保持一个内存池，所有分配内存的请求全都从内存池分配，然后请求结束，直接销毁内存池，这样简化了内存的分配与回收操作。为了避免出现内存泄露的问题，我们在模块中一般都在请求结构体的内存池中分配内存，那就涉及到nginx提供的几个内存分配函数::

        void *ngx_palloc(ngx_pool_t *pool, size_t size);
        void *ngx_pnalloc(ngx_pool_t *pool, size_t size);
        void *ngx_pcalloc(ngx_pool_t *pool, size_t size);

3个函数签名完全一致，两个参数，内存池和大小，那这3个函数有何不同呢，我们在使用的时候应该怎么选择呢？
首先ngx_palloc和ngx_pcalloc的区别就是ngx_pcalloc在申请完内存之后使用ngx_memzero把内存置0，而ngx_palloc对申请来的小块内存会默认基于机器字长(在某些特殊cpu架构下会是16)进行内存对齐操作，而ngx_pnalloc则不会进行对齐操作。
这样引入了一个内存对齐的概念，我们来简单了解下。
如果一个变量的内存地址正好位于它长度的整数倍，那么这个变量就被称做自然对齐。
为什么要做对齐呢，因为每次cpu去取数据的话会按照对齐的方式去取，比如对于32位字长的cpu来说，读取内存时候0x00000000，0x00000004，....依次读取，这样如果一个四字节数据放在非对齐的位置上，比如0x00000002-0x00000005上，那cpu需要取一次0x00000000拿到0x00000002-0x00000003，然后还要取一次0x00000004，拿到0x00000004-0x00000005，这样实际上两次取才能取到需要的四字节数据，是非常低效的，如果我们能把这个数据放到对齐的位置上，那么cpu一次就能取出来。
如果我们申请一个非常小的空间的话，比如单个char，实际上不管怎样都是对齐的，这样就没有必要使用ngx_palloc多一次内存对齐的操作。

nginx定义了3个内存复制函数，根本上还是对memcpy的封装，加了一些特殊的处理。

+ ngx_memcpy
如果定义了NGX_MEMCPY_LIMIT那么在memcpy的基础上判断复制内存大小是否超过了NGX_MEMCPY_LIMIT。

+ ngx_copy
对ngx_cpymem进行了特殊条件下的优化，当在某个特殊cpu架构下，如果长度小于17个字节就进行逐个字符的复制。

+ ngx_cpymem
在ngx_memcpy的基础上返回值上加上复制的内存的大小，也就是返回值为copy完之后的数据的末尾。


request结构体
++++++++++++++

结构体声明::

        struct ngx_http_request_s { 
            ...
            //这个请求的内存池，请求开始的时候创建，请求结束销毁
            ngx_pool_t                       *pool;  
            ...
            //ngx_http_process_request_headers在接收、解析完http请求的头部后，会把解析完的每一个http头部加入到headers_in的headers链表中，同时会构造headers_in中的其他成员  
            ngx_http_headers_in_t             headers_in;  
            //http模块会把想要发送的http相应信息放到headers_out中，最终作为http响应包的header返回给用户，如果想设置header要把header放到这个结构体中  
            ngx_http_headers_out_t            headers_out; 
        
            ...
            //当前请求开始的时间  
            time_t                            start_sec;  
            ngx_msec_t                        start_msec;
        
            /*当前请求既有可能是用户发来的请求，也可能是派生出的子请求。
             * 而main标识一系列相关的派生子请求的原始请求。
             * 一般可通过main和当前请求的地址是否相等来判断当前请求是否为用户发来的原始请求。
            */  
            ngx_http_request_t               *main; 
        }

我们看到request结构体中有一个headers_out的字段，我们如何来设置一个response的header呢？
在我们的模块中set cookie的方式如下，cookie变量中存放的是cookie的字符串，在r->headers_out.headers中push进去一个header::

    set_cookie = ngx_list_push(&r->headers_out.headers);
    if (set_cookie == NULL) {
        return NGX_ERROR;
    }

    set_cookie->hash = 1;
    ngx_str_set(&set_cookie->key, "Set-Cookie");
    set_cookie->value.len = p - cookie;
    set_cookie->value.data = cookie;


nginx变量
++++++++++++++
在Nginx中同一个请求需要在模块之间数据的传递或者说在配置文件里面使用模块动态的数据一般来说都是使用变量，比如在HTTP模块中导出了host/remote_addr等变量，这样我们就可以在配置文件中以及在其他的模块使用这个变量。在Nginx中，有两种定义变量的方式，一种是在配置文件中,使用set指令，一种就是上面我们提到的在模块中定义变量，然后导出.
nginx有一些预定义的特殊形式的变量，我们在命名的时候一定要避开
- arg_name http请求的uri中得请求参数name
- http_name http请求header中的参数name，需要注意的是如果http header中变量命名为x-forwarded-for，访问时要使用http_x_forwarded_for，注意将-替换为_同时使用小写
- cookie_name cookie中的变量name

`nginx预定义变量列表 <http://nginx.org/en/docs/http/ngx_http_core_module.html#variables/>`_

我们如何在nginx中添加一个变量呢，先来看下变量的结构体定义::

        struct ngx_http_variable_s {
            ngx_str_t                     name;   /* must be first to build the hash */
            ngx_http_set_variable_pt      set_handler;
            ngx_http_get_variable_pt      get_handler;
            uintptr_t                     data;
            ngx_uint_t                    flags;
            ngx_uint_t                    index;
        };

这里要注意flag属性,flag属性就是由下面的几个属性组合而成::

        #define NGX_HTTP_VAR_CHANGEABLE   1
        #define NGX_HTTP_VAR_NOCACHEABLE  2
        #define NGX_HTTP_VAR_INDEXED      4
        #define NGX_HTTP_VAR_NOHASH       8

- NGX_HTTP_VAR_CHANGEABLE
表示这个变量是可变的.Nginx有很多内置变量是不可变的，比如arg_xxx这类变量，如果你使用set指令来修改，那么Nginx就会报错.

- NGX_HTTP_VAR_NOCACHEABLE
表示这个变量每次都要去取值，而不是直接返回上次cache的值(配合对应的接口).

- NGX_HTTP_VAR_INDEXED
表示这个变量是用索引读取的.

- NGX_HTTP_VAR_NOHASH
表示这个变量不需要被hash.

添加变量::

        ngx_http_variable_t *ngx_http_add_variable(ngx_conf_t *cf, ngx_str_t *name, ngx_uint_t flags);

我们在logid模块中添加变量的实例::

    ngx_http_variable_t *var;

    var = ngx_http_add_variable(cf, &ngx_http_logid,
                                NGX_HTTP_VAR_CHANGEABLE);
    if (var == NULL)
    {   
        return NGX_ERROR;
    }   

    var->get_handler = ngx_http_logid_set_variable;

而对应的获取变量的函数为::

        ngx_http_variable_value_t *ngx_http_get_variable(ngx_http_request_t *r, ngx_str_t *name, ngx_uint_t key);

前两个参数都比较容易理解，一个是request对象，一个是变量名，最后一个是什么呢？
最后一个key是变量名的哈希值，看下我们在logid模块中是如何获取这个key值然后得到变量值的::

        src = ngx_pnalloc(r->pool, ngx_http_logid.len);
        ngx_memcpy(src, ngx_http_logid.data, ngx_http_logid.len);
        key = ngx_hash_strlow(src, src, ngx_http_logid.len);
        v = ngx_http_get_variable(r, &ngx_http_logid, key);

其中ngx_http_logid是字符串"logid"，然后通过ngx_hash_strlow生成对应的key值。

模块配置结构体定义
******************
模块可以定义三个配置结构体，分别给main，server和location。命名规则一般为ngx_http_<module name>_(main|srv|loc)_conf_t
一般来讲如果在每个context下配置方式都一样的话一个结构体就够了
我们的logid模块定义结构体如下::

        typedef struct
        {
            ngx_flag_t    enable;
        
            ngx_flag_t    cookie_enable;
            ngx_str_t     cookie_name;
            ngx_str_t     cookie_domain;
            ngx_str_t     cookie_path;
            time_t        cookie_expire_time;
        } ngx_http_logid_conf_t;

其中enable用来标识是否启用logid模块，cookie_enable标识是否启用logid的cookie功能，然后后边的分别为cookie的名字，域，路径和过期时间。

模块指令
********
模块指令的结构体::

        struct ngx_command_t {
            ngx_str_t             name;
            ngx_uint_t            type;
            char               *(*set)(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
            ngx_uint_t            conf;
            ngx_uint_t            offset;
            void                 *post;
        };

- name
指令名字

- type
指令的类型，用来指示在什么条件下指令是有效的，接收多少个参数，下面是type常用的一些参数，以'|'来添加多个参数::

        NGX_HTTP_MAIN_CONF: 指令在http配置块中有效
        NGX_HTTP_SRV_CONF: 指令在server段有效
        NGX_HTTP_LOC_CONF: 指令在location配置中有效
        NGX_HTTP_UPS_CONF: 指令在upstream配置中有效
        NGX_HTTP_SIF_CONF 指令在server段的if中有效
        NGX_HTTP_LIF_CONF 指令在location段的if中有效
        
        NGX_CONF_NOARGS: 指令不需要传递参数
        NGX_CONF_TAKE1: 指令需要传一个参数
        NGX_CONF_TAKE2: 指令需要传两个参数
        …
        NGX_CONF_TAKE7: 需要传7个参数
        NGX_CONF_FLAG: 指令接受一个boolean值("on" or "off")
        NGX_CONF_1MORE: 指令至少需要传一个参数
        NGX_CONF_2MORE: 指令至少需要传两个参数


- set
在src/core/ngx_conf_file有对应各种类型的设置函数，命名方式一般为：ngx_conf_set_xxx_slot，比如
ngx_conf_set_str_slot
ngx_conf_set_flag_slot
ngx_conf_set_str_array_slot

- conf
用来告诉nginx把变量保存到哪里，NGX_HTTP_MAIN_CONF_OFFSET，NGX_HTTP_SRV_CONF_OFFSET,  NGX_HTTP_LOC_CONF_OFFSET分别表示把变量保存到main configuration，server configuration,或者location configuration

- offset
用来标识应该把变量值写到配置结构体的什么位置上。

- post
存储一个指针。可以指向任何一个在读取配置过程中需要的数据，以便于进行配置读取的处理。大多数时候，都不需要，所以简单地设为NULL即可。

模块定义与上下文
**********************
一般的模块的定义方式如下::

        ngx_module_t  ngx_http_<module name>_module = {
            NGX_MODULE_V1,
            &ngx_http_<module name>_module_ctx, /* module context */
            ngx_http_<module name>_commands,   /* module directives */
            NGX_HTTP_MODULE,               /* module type */
            NULL,                          /* init master */
            NULL,                          /* init module */
            NULL,                          /* init process */
            NULL,                          /* init thread */
            NULL,                          /* exit thread */
            NULL,                          /* exit process */
            NULL,                          /* exit master */
            NGX_MODULE_V1_PADDING
        };

我们在logid模块中，模块的定义和模块上下文的定义如下::

        ngx_module_t ngx_http_logid_module =
        {
            NGX_MODULE_V1,
            &ngx_http_logid_module_ctx,        /* module context */
            ngx_http_logid_commands,           /* module directives */
            NGX_HTTP_MODULE,                       /* module type */
            NULL,                                  /* init master */
            NULL,                                  /* init module */
            NULL,                                  /* init process */
            NULL,                                  /* init thread */
            NULL,                                  /* exit thread */
            NULL,                                  /* exit process */
            NULL,                                  /* exit master */
            NGX_MODULE_V1_PADDING
        };

        static ngx_http_module_t ngx_http_logid_module_ctx =
        {
            NULL,      /* preconfiguration */
            ngx_http_logid_init,                                  /* postconfiguration */
        
            NULL,                                  /* create main configuration */
            NULL,                                  /* init main configuration */
        
            NULL,                                  /* create server configuration */
            NULL,                                  /* merge server configuration */
        
            ngx_http_logid_create_conf,        /* create location configration */
            ngx_http_logid_merge_conf          /* merge location configration */
        };

filter链
****************
过滤模块使用的是职责链模式，模块调用时有对应顺序的，先注册后调用它的顺序在编译的时候就决定了。控制编译的脚本位于auto/modules中，当你编译完Nginx以后，可以在objs目录下面看到一个ngx_modules.c的文件。打开这个文件，有类似的代码::

        ngx_module_t *ngx_modules[] = { 
            &ngx_core_module,
            &ngx_errlog_module,
            &ngx_conf_module,
            &ngx_events_module,
            &ngx_event_core_module,
            &ngx_epoll_module,
            &ngx_http_module,
            &ngx_http_core_module,
            &ngx_http_log_module,
            &ngx_http_upstream_module,
            &ngx_http_static_module,
            &ngx_http_autoindex_module,
            &ngx_http_index_module,
            &ngx_http_auth_basic_module,
            &ngx_http_access_module,
            &ngx_http_limit_conn_module,
            &ngx_http_limit_req_module,
            &ngx_http_geo_module,
            &ngx_http_map_module,
            &ngx_http_split_clients_module,
            &ngx_http_referer_module,
            &ngx_http_proxy_module,
            &ngx_http_fastcgi_module,
            &ngx_http_uwsgi_module,
            &ngx_http_scgi_module,
            &ngx_http_memcached_module,
            &ngx_http_empty_gif_module,
            &ngx_http_browser_module,
            &ngx_http_upstream_ip_hash_module,
            &ngx_http_upstream_least_conn_module,
            &ngx_http_upstream_keepalive_module,
            &ngx_http_write_filter_module,
            &ngx_http_header_filter_module,
            &ngx_http_chunked_filter_module,
            &ngx_http_range_header_filter_module,
            &ngx_http_gzip_filter_module,
            &ngx_http_postpone_filter_module,
            &ngx_http_ssi_filter_module,
            &ngx_http_charset_filter_module,
            &ngx_http_userid_filter_module,
            &ngx_http_headers_filter_module,
            &ngx_http_logid_module,
            &ngx_http_copy_filter_module,
            &ngx_http_range_body_filter_module,
            &ngx_http_not_modified_filter_module,
            NULL
        };

按照上边的顺序倒序执行，先执行的是ngx_http_not_modified_filter_module，然后各个模块顺序执行。
从上面可以看到我们的logid模块，是位于ngx_http_copy_filter_module和ngx_http_headers_filter_module之间的。

注册header filter和body filter的方式如下，将我们要加入的模块放到header的位置上::

        static ngx_http_output_header_filter_pt ngx_http_next_header_filter;
        static ngx_int_t
        ngx_http_chunked_filter_init(ngx_conf_t *cf)
        {
            ngx_http_next_header_filter = ngx_http_top_header_filter;
            ngx_http_top_header_filter = ngx_http_xxx_header_filter;
        
            ngx_http_next_body_filter = ngx_http_top_body_filter;
            ngx_http_top_body_filter = ngx_http_xxx_body_filter;
        
            return NGX_OK;
        }

而在header filter的具体实现函数ngx_http_xxx_header_filter中，当我们的逻辑正常执行完成需要调用::

        return ngx_http_next_body_filter();

告诉nginx去执行下一个filter，而发生错误的时候需要返回错误码，例如NGX_ERROR。

模块的编译与使用
****************
我们需要一个config文件来告诉nginx的编译脚本如何对这个模块进行编译，我们在config文件中会配置好模块的名字，对应的代码文件的名字等，下边看我们logid模块config文件的内容::

        ngx_addon_name=ngx_http_logid_module
        HTTP_AUX_FILTER_MODULES="$HTTP_AUX_FILTER_MODULES ngx_http_logid_module"
        LOGID_SRCS="$ngx_addon_dir/ngx_http_logid_module.c"
        NGX_ADDON_SRCS="$NGX_ADDON_SRCS $LOGID_SRCS"

在nginx的源码目录中执行configure::

./configure --prefix=/usr/local/nginx/ --add-module=path-to-module-folder

然后configure会找到这个目录下的config，将模块编译进nginx中，然后就可以使用了。

在配置文件中使用的示例::

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" "$logid"'
                      '"$http_user_agent" "$http_x_forwarded_for"';

    server {
        listen       9999;
        server_name  www.logid.com;
        access_log  logs/logid.access.log  main;
        error_log  logs/logid.error.log  debug;
        logid on; 
        logid_cookie on; 
        logid_cookie_name "logid";
        logid_cookie_domain "*.logid.com";
        logid_cookie_path "/";
        logid_cookie_expire 1d;
        location / { 
            root   html;
            index  index.html index.htm;
        }   
    }

.. include:: dashang.rst

