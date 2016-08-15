.. _periodical-201608-huangqiuping:

mysql分区技术简介
===================

.. contents:: 目录

引言
-------

目前，我们的web架构大多是nginx+php+mysql，用mysql来存储数据。当数据库中表数据量涨到一定数量时（存储了百万级乃至千万级条记录），性能就成为我们不能不关注的问题，如何优化呢？常用的大致有如下几种：拆分业务、分表、分区。每种情况都有合适的应用场景，相信前两者大家都很熟悉，下面我们展开介绍的是分区，即所有的数据还放在一个表中，但物理存储数据根据一定的规则存放在不同的文件中，文件可以放到同一块磁盘也可以在不同的机器另外磁盘上。

分区优点
---------

1. 维护成本低。如果一个成熟的业务遇到瓶颈后引入表分区技术，与分表比起来代码维护量小，基本不用改动，且不需额外创建子表。

#. 加大了存储容量。分区在把数据根据一定规则划分后可以存放在多个位置，可以是同一块磁盘也可以是不同的机器。因此和单个磁盘或者文件系统分区比起来一个表可以存放更多的数据。

#. 数据更容易维护。例如，按年份划分的数据分区，当想把过去某一年的数据删除时，只需简单的把存放对应年份的分区删除，且不影响余下分区的数据完整性。此外分区是由MySQL系统直接管理的，DBA不需要手工的去划分和维护。可以对一个独立分区进行优化、检查、修复等操作。

#. 性能提升。在某些查询语句中，where语句携带的查询条件包含的数据只存在特定的某一个或者几个分区，mysql的优化器可以自动排除其他分区，只从特定的分区中查询需要的数据，大大的优化了查询效率。另外，当多个分区分别存储在不同的磁盘上，同时访问多个分区时可以减少物理I/O争用。

分区类型
---------

目前主要有4种分区类型，range、list、hash、key。

range分区
**********

采用range分区的表，每个分区存放的是分区表达式的值落在给定范围内的行，范围必须是连续且不能重叠的，并且使用VALUES LESS THAN操作符。例如，假设创建如下的表用来存放连续的20家音像店记录，从1到20。

::

    CREATE TABLE employees (
        id INT NOT NULL,
        fname VARCHAR(30),
        lname VARCHAR(30),
        hired DATE NOT NULL DEFAULT '1970-01-01',
        separated DATE NOT NULL DEFAULT '9999-12-31',
        job_code INT NOT NULL,
        store_id INT NOT NULL
    );                          

根据不同需求，这个表可以使用多种不同的分区方式，其中一种是使用store_id字段，例如：如果想把一个表分成4个分区可以加入如下的PARTITION BY RANGE 子句：

::

    CREATE TABLE employees (
        id INT NOT NULL,
        fname VARCHAR(30),
        lname VARCHAR(30),
        hired DATE NOT NULL DEFAULT '1970-01-01',
        separated DATE NOT NULL DEFAULT '9999-12-31',
        job_code INT NOT NULL,
        store_id INT NOT NULL
    )
    PARTITION BY RANGE (store_id) (
        PARTITION p0 VALUES LESS THAN (6),
        PARTITION p1 VALUES LESS THAN (11),
        PARTITION p2 VALUES LESS THAN (16),
        PARTITION p3 VALUES LESS THAN (21)
    );

在这种分区模式下，所有在商店1～5工作的员工信息将会被存在分区p0，在6～10的被存在分区p1，以此类推。注意到分区是按顺序定义的，从低到高。当准备插入一条新记录(72, 'Mitchell', 'Wilson', '1998-06-25', NULL, 13)时，可以直接插入到p2，但是当如果有一条记录是21号商店，因为找不到对应的分区将会报错，可以通过把上面最后一行分区3替换为 ``PARTITION p3 VALUES LESS THAN MAXVALU`` 。其中，MAXVALUE代表整数中的最大值，现在任何大于等于16号商店的记录都可以存储在分区p3中。将来，如果商店增加到25，30甚至更多，可以通过ALTER TABLE新增21～25， 26～30等新分区。

除了如上使用int字段类型的store_id来分区表，还可以任选一个DATE类型的列组成的表达式实现表分区，例如：

::

    CREATE TABLE employees (
        id INT NOT NULL,
        fname VARCHAR(30),
        lname VARCHAR(30),
        hired DATE NOT NULL DEFAULT '1970-01-01',
        separated DATE NOT NULL DEFAULT '9999-12-31',
        job_code INT,
        store_id INT
    )
    PARTITION BY RANGE ( YEAR(separated) ) (
        PARTITION p0 VALUES LESS THAN (1991),
        PARTITION p1 VALUES LESS THAN (1996),
        PARTITION p2 VALUES LESS THAN (2001),
        PARTITION p3 VALUES LESS THAN MAXVALUE
    );

在这个模式下，所有在1991年前离开的的员工信息存在p0分区，在1991～1995年间离开的员工信息存在p1分区，在1996～2000年间离开的员工信息存在p2分区，2000年后离开的员工信息存在p3分区。

在遇到以下一种或多种条件时，Range分区尤其有用：

1. 不需要老数据了，比如上表中要删除1991年前就离开公司的员工信息，可以简单的使用“ALTER TABLE employees DROP PARTITION p0”；对于含有大量记录的表，删除分区比直接使用DELETE操作“DELETE FROM employees WHERE YEAR(separated)”高效很多。

#. 想使用包含date 或者time值或者其他系列产生的值的列。

#. 频繁的执行直接依赖用于分区表的列的查询语句。例如，执行“EXPLAIN PARTITIONS SELECT COUNT(*) FROM employees WHERE separated BETWEEN '2000-01-01' AND '2000-12-31' GROUP BY store_id;”mysql可以很快判断只有p2分区需要被扫描，因为其余的分区不可能包含满足where子句的记录。

list分区
************

list分区在很多方面都类似于range分区，两者之间最主要的区别是，在list分区中每个分区的定义和选择是基于列值是否在一组值的列表中而不是在一组连续的范围值中。要实现list分区，可以通过使用PARTITION BY LIST(expr) 子句，并且使用VALUES IN（value_list）来定义每个分区；其中expr可以是一个列的值，也可以是一个基于列值的表达式且该表达式返回一个整数值，value_list是通过，分隔的整数列表。

还是以上面employees表为例，假设20家音像店分布在如下表所示的4个区域，

=========================  =================== 
         Region             Store ID Numbers   
=========================  =================== 
 North                      3,5,6,9,17
 East                       1,2,10,11,19,20
 West                       4,12,13,14,18
 Central                    7,8,15,16
=========================  ===================

如果要把属于同一区域的商店记录存储在同一个分区，可以使用如下的分区语句：

::

    CREATE TABLE employees (
        id INT NOT NULL,
        fname VARCHAR(30),
        lname VARCHAR(30),
        hired DATE NOT NULL DEFAULT '1970-01-01',
        separated DATE NOT NULL DEFAULT '9999-12-31',
        job_code INT,
        store_id INT
    )
    PARTITION BY LIST(store_id) (
        PARTITION pNorth VALUES IN (3,5,6,9,17),
        PARTITION pEast VALUES IN (1,2,10,11,19,20),
        PARTITION pWest VALUES IN (4,12,13,14,18),
        PARTITION pCentral VALUES IN (7,8,15,16)
    );

如此分区后，可以很容易就把和特定区域相关的员工记录添加到表中或从表中删除。假设所有位于西部地区的商店都卖个另一家公司后，所有在那个区印象店工作的员工记录都可以通过执行“ALTER TABLE employees TRUNCATE PARTITION pWest”来删除，这比执行删除语句“DELETE FROM employees WHERE store_id IN (4,12,13,14,18);”高效很多。如果使用“ ALTER TABLE employees DROP PARTITION pWest”也可以把那些员工记录删除，但是同时会把pWest分区从表定义中删除，还得再次使用“ALTER TABLE ... ADD PARTITION”语句来恢复原来的表分区模式。

和RANGE分区不同的还有一点，LIST分区没有像MAXVALUE这种可以包含剩下的所有记录，分区表达式中的所有预期值都必须包含在PARTITION ... VALUES IN (...)中。如果插入一条包含未匹配的分区列的值将会失败并且报错，如下：

::

    mysql>CREATE TABLE h2 (
        ->c1 INT,
        ->c2 INT
        ->)
        ->PARTITION BY LIST(c1) (
        ->PARTITION p0 VALUES IN (1, 4, 7),
        ->PARTITION p1 VALUES IN (2, 5, 8)
        ->);
    Query OK, 0 rows affected (0.11 sec)

    mysql>INSERT INTO h2 VALUES (3, 5);
    ERROR 1525 (HY000): Table has no partition for value 3

当使用INSERT语句批量插入多行是，不同的引擎表现不一样。比如Innodb存储引擎中的表，整条插入语句被看作一个事务，因此如果出现任何未匹配的值将导致所有记录都插入失败。而MyISAM引擎中，在未匹配值之前的行记录都可以被插入，后面的行则不行。

hash分区
**********

hash分区主要用来把数据均衡地分布于预定义好的分区里。在rang和list分区里，需要显示指定一个或者一系列列值保存在那个分区，而在hash分区里，这些都由MYSQL来决定，开发者只需要指定一个列值或是基于列值的表达式用于hash分区及想要把表分成多少个分区的数值。

创建hash分区需要“PARTITION BY HASH (expr)”子句，其中expr是一个返回整数值的表达式，此处也可以指定一个整数类型的列名。此外一般还在后面加上“PARTITIONS num”子句，num必须是一个正整数代表分区数目。下面的例子以store_id列名作为hash表达式，把表分成4个分区：

::

    CREATE TABLE employees (
        id INT NOT NULL,
        fname VARCHAR(30),
        lname VARCHAR(30),
        hired DATE NOT NULL DEFAULT '1970-01-01',
        separated DATE NOT NULL DEFAULT '9999-12-31',
        job_code INT,
        store_id INT
    )
    PARTITION BY HASH(store_id)
    PARTITIONS 4;
     
如果没有包含PARTITIONS字句，默认表分区数为1。也可以基于雇用员工日期作为hash分区，例如：

::

    CREATE TABLE employees (
        id INT NOT NULL,
        fname VARCHAR(30),
        lname VARCHAR(30),
        hired DATE NOT NULL DEFAULT '1970-01-01',
        separated DATE NOT NULL DEFAULT '9999-12-31',
        job_code INT,
        store_id INT
    )
    PARTITION BY HASH( YEAR(hired) )
    PARTITIONS 4;

Expr表达式必须返回一个非常量、非随机的整数值。但同时要记住每插入或者更新或者删除一行，这个表达式都会被计算一次，这意味着非常复杂的表达式将产生性能问题，尤其是像执行批量操作那种同时会影响一堆行记录时更为严重。效率最高的表达式是那种随着列值升降变化表达式值也会跟着升降改变的。

例如假设date_col是个DATE类型的值，TO_DAYS(date_col)和YEAR(date_col)都是一个好的表达式，前者不用多说，列值一变化表达式值也跟着变化，后者虽然不是每个列值变化表达式值都会变化，但是表达式值仍是随一定比例的列值变化而变，且不会产生比例失调的表达式值。

再举个反例，如表达式POW(5-int_col,3) + 6，int_col是一个int型列，当int_col从5到6，表达式值从6到5，趋势是-1；当int_col从6到7，表达式值从5到-2，趋势是-7。这是一个糟糕的表达式，因为无法确保列值变化时表达式成比例变化。

总之，表达式越趋近于y=cx，越适合作为hash分区，其中c是非0常数。


key分区
*********

key分区类似于hash分区，本质区别是hash分区使用的是用户自定义的表达式，而key分区函数是由MySQL 服务器提供的，不同的存储引擎使用不同的内部函数。
创建key分区的语法和hash分区差不多，除了下面2点区别：

1. 关键字由HASH替换为KEY，例如PARTITION BY KEY()
#. KEY中包含0个或者多个列名。如果一个表有主键的话那么任何被用于key分区的列必须是表中主键的一部分。若表中有定义主键，且key分区中不包含任何一个列名，则表的主键列将会被用于key分区。如下：::

    CREATE TABLE k1 (
    id INT NOT NULL PRIMARY KEY,
    name VARCHAR(20)
    )
    PARTITION BY KEY()
    PARTITIONS 2;

如果没有主键但是有唯一索引，则将使用唯一索引作为key分区，例如：::

    CREATE TABLE k1 (
        id INT NOT NULL,
        name VARCHAR(20),
        UNIQUE KEY (id)
    )
    PARTITION BY KEY()
    PARTITIONS 2;
 
上例中，如果唯一索引列没有被定义为NOT NULL，则会报错。在上面两个例子中，用于key分区的都是id列。

不像其他分区类型，用于KEY分区的列并不严格限制必须是整数或者NULL值，例如下面的语句是合法的，KEY中的列是字符型：::

    CREATE TABLE tm1 (
        s1 CHAR(32) PRIMARY KEY
    )
    PARTITION BY KEY(s1)
    PARTITIONS 10;
                     
由于s1是表的主键，上例中也可以直接使用PARTITION BY KEY()。


分区注意事项
--------------

NULL值的处理
**************

MySQL中的分区在禁止空值（NULL）上没有进行处理。在RANGE分区中，无论是插入一个列值为NULL或者表达式值为NULL的记录，都被当作是小于任何其他值，会默认被保存在从低到高排好序的第一个分区。在LIST分区中，如果所有分区LIST列表值里都没有NULL值，则插入含有NULL值的记录时会报错。ERROR 1504 (HY000): Table has no partition for value NULL。在hash和key分区中NULL值则都当作0处理。

如果希望回避这种做法，应该在设计表时不允许空值；最可能的方法是，通过声明列“NOT NULL”来实现这一点。

分区索引、主键和唯一索引的关系
********************************

表中每一个唯一索引都应该包含分区表达式中的所有列，由于主键也是一种唯一索引，所以主键也有如上要求。下面的建表语句都是不合法的：::

    CREATE TABLE t1 (
        col1 INT NOT NULL,
        col2 DATE NOT NULL,
        col3 INT NOT NULL,
        col4 INT NOT NULL,
        UNIQUE KEY (col1, col2)
    )
    PARTITION BY HASH(col3)
    PARTITIONS 4;

    CREATE TABLE t2 (
        col1 INT NOT NULL,
        col2 DATE NOT NULL,
        col3 INT NOT NULL,
        col4 INT NOT NULL,
        UNIQUE KEY (col1),
        UNIQUE KEY (col3)
    )
    PARTITION BY HASH(col1 + col3)
    PARTITIONS 4;

在每个建表语句中，都至少有一个唯一索引没有包含表达式中的所有列。改成如下形式才是合法的：::

    CREATE TABLE t1 (
        col1 INT NOT NULL,
        col2 DATE NOT NULL,
        col3 INT NOT NULL,
        col4 INT NOT NULL,
        UNIQUE KEY (col1, col2, col3)
    )
    PARTITION BY HASH(col3)
    PARTITIONS 4;

    CREATE TABLE t2 (
        col1 INT NOT NULL,
        col2 DATE NOT NULL,
        col3 INT NOT NULL,
        col4 INT NOT NULL,
        UNIQUE KEY (col1, col3)
    )
    PARTITION BY HASH(col1 + col3)
    PARTITIONS 4;

如果一个表没有唯一索引（也没有主键），则没有此限制，在每个分区类型里只要列的类型符合就可以当作分区表达式。但是如果事后修改分区表结构，加了唯一索引的话仍然有这个限制。例如：::

    mysql> CREATE TABLE t_no_pk (c1 INT, c2 INT)
        ->     PARTITION BY RANGE(c1) (
        ->         PARTITION p0 VALUES LESS THAN (10),
        ->         PARTITION p1 VALUES LESS THAN (20),
        ->         PARTITION p2 VALUES LESS THAN (30),
        ->         PARTITION p3 VALUES LESS THAN (40)
        ->     );
    Query OK, 0 rows affected (0.12 sec)

分别给表t_no_pk添加主键，如下面3种，前2种是合法的，第3种将报错：::

    #  possible PK
    mysql> ALTER TABLE t_no_pk ADD PRIMARY KEY(c1);
    Query OK, 0 rows affected (0.13 sec)
    Records: 0  Duplicates: 0  Warnings: 0

    #  use another possible PK
    mysql> ALTER TABLE t_no_pk ADD PRIMARY KEY(c1, c2);
    Query OK, 0 rows affected (0.12 sec)
    Records: 0  Duplicates: 0  Warnings: 0

    #  fails with error 1503
    mysql> ALTER TABLE t_no_pk ADD PRIMARY KEY(c2);
    ERROR 1503 (HY000): A PRIMARY KEY must include all columns in the table's partitioning function

此外，当想把一个非分区表改成分区表时，同样要满足此索引规则。


小结
----------

本文仅是一个科普，主要介绍了什么是表分区，分区的几种类型，优点及注意事项。当表非常大以至于无法把全部数据放在内存中，或者只在表的最后部分有热点数据，其他都是历史数据时，非常适合使用分区。

但在使用时也要注意分区的限制，比如分区表无法使用外键约束；或者使用分区时每插入一行数据都需要按照表达式筛选插入的分区地址，当业务插入操作很多时可以权衡下；或者如果索引列和分区列不匹配，且查询中没有包含过滤分区的条件,会导致无法进行分区过滤，那么将会导致查询所有分区。
