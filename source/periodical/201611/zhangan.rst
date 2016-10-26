.. _periodical-201611-zhangan:

近期在写golang中遇到的一些小问题
================================================

.. contents:: 目录


无法修改map中的成员变量
------------------------

在开始代码设计的时候想要将原struct中的成员变量进行修改或者替换。

代码示例如下

::

    package main
    
    import "fmt"
    
    var m = map[string]struct{ x, y int } {
        "foo": {2, 3}
    }
    
    func main() {
        m["foo"].x = 4
        fmt.Printf("result is : %+v", m)
    }


本以为这个会将 m["foo"] 中的 x 替换成 4， 从而打印出来的效果是

``result is : map[foo:{x:4 y:3}]``

然而，并不是的，这段代码在保存后编译时提示
    
``cannot assign to struct field m["foo"].x in map``

这就尴尬了，无法在已经存在的key的节点中修改值，这是为什么？

m中已经存在"foo"这个节点了啊，

然后就去google搜了下，然后看到在github上有人提到这个问题，
问题地址 `issue-3117 <https://github.com/golang/go/issues/3117>`_

`ianlancetaylor <https://github.com/ianlancetaylor>`_  回答给出了一个比较能理解的解释。

简单来说就是map不是一个并发安全的结构，所以，并不能修改他在结构体中的值。

这如果目前的形式不能修改的话，就面临两种选择，

1.修改原来的设计;

2.想办法让map中的成员变量可以修改，

因为懒得该这个结构体，就选择了方法2，

但是不支持这种方式传递值，应该如何进行修改现在已经存在在struct中的map的成员变量呢？

热心的网友们倒是提供了一种方式，示例如下：

::

    package main
    
    import "fmt"

    var m = map[string]struct{ x, y int } {
        "foo": {2, 3}
    }

    func main() {
        tmp := m["foo"]
        tmp.x = 4
        m["foo"] = tmp
        fmt.Printf("result is : %+v", m)
    } 

果然和预期结果一致，不过，总是觉得有点怪怪的，

既然是使用了类似临时空间的方式，那我们用地址引用传值不也是一样的么...

于是，我们就使用了另外一种方式来处理这个东西，

示例如下：

::
    
 package main

 import "fmt"

 var m = map[string]*struct{ x, y int } {
     "foo": &{2, 3}
 }

 func main() {
    m["foo"].x = 4
    fmt.Println("result is : %+v \n", m)
    fmt.Println("m's node is : %+v \n", *m["foo"])
 }

最后的展示结果为：

::

 result is : map[foo:0xc42000cff0]
 m's node is : {4, 3} 

多亏了经过这么一番折腾，我知道了，下次要是想在struct中的map里面改变成员变量，就直接用地址吧。


Golang中IDGEN的使用
-----------------------

* **使用的版本介绍**

    1. **go**: ``1.6.2``
    
    #. **go-sql-driver**: ``1.2(release)``

* **错误代码示例**

    ::
        
         func IdGen() int{
            updateIdGenQuery := "UPDATE id_gen SET last_id = last_insert_id(last_id + 1)"
            res, err := stam.Exec(updateIdGenQuery)
        
            rowAfffect, rowErr := res.RowAffected()
        
            ....//error 处理
        
            getLastId := stam.QueryRow("SELECT last_insert_id() AS last_id")
            
            var lastId int
            err = getLastId.Scan(&lastId)
        
            ....//error 处理
        
            return lastId
         }
 

* **错误使用出现的现象**

  在单机测试过程中没有出现问题，然后开始小规模内部调用测试，
  
  这个时候部分同学使用在使用后发现，有些接口调用不成功，
  
  马上查看操作记录部分的日志，看到例如无法添加数据，数据已经存在等等...

  再通过记录的数据库操作日志来看，sql语句是拼装好了，确实也是返回的错误值...继续排查！
  
* **排查错误**

  经过逐步定位，我们追到了这个idgen生成的地方，
  
  这次我们使用方式在上述代码的getLastId那一行添加了个 goroutine

  ::
  
    i := 0

    for i < 100 {
        go func(){
              getLastId := stam.QueryRow("SELECT last_insert_id() AS last_id")
              var lastId int
              getLastId.Scan(&lastId)
              println(lastId)
        }()
    }

  添加这个goroutine的目的也是为了检测在多个同学一起使用的时候last_insert_id()是否是预期的值，

  结果确实返回的都是非预期的值，这样就算是基本确定了问题在这了。

  在通过查找golang/pkg的文档中，找到了关于获取最后更新id的使用方法， 
  `database/sql/#Result <https://golang.org/pkg/database/sql/#Result>`_

* **修改代码**

  后将代码修改为：

  ::

   res, err := stam.Exec(updateIdgenQuery)
   lastId, lastIdErr := res.LastInsertId()

   return lastId

关于golang使用mysql-proxyz的问题
-----------------------------------

经过各种调试后，我们准备对程序进行上线前的最后一次检验，压力测试，

在没有并发的情况下，一切都很好，和想象中一样的美好，当添加并发的时候

又出现了问题，这次的报错是

``Error 1243: Unknown prepared statement handler (1) given to mysqld_stmt_execute``

找了下google，找了下DBA，基本确定了是mysql-proxy对prepare的不支持，导致的这个问题，

DBA同学给了一篇文章，让我们看下， `Atlas支持mysql的prepare特性吗 <http://mp.weixin.qq.com/s?__biz=MzIxMjM2OTc0OQ==&mid=2247483699&idx=1&sn=b663176647386cfcebb4785c60f71e97&mpshare=1&scene=1&srcid=1010esXv1Y6PCWSMLYRYxUvT#wechat_redirect>`_

文章看完后，还是继续google这个问题出现原因吧，

整理下网上关于这个问题的各种解答就是说，mysql-proxy本身就是不太支持prepare的，

之所以我们之前是可以使用的原因，是有先驱们在各个语言中自己实现了一下，= =||

然后，在不经意间看到一个解决办法， `go-sql-driver/mysql/issue/455 <https://github.com/go-sql-driver/mysql/issues/455>`_ 

提问者自己抛出了一个得到肯定答复的反问句

``may i use interpolateParams to slove this problem ?``

然后，我们也悄悄的加上了这个参数，果然，关于Error 1243 的报错全没有了~

虽然很不优雅...
