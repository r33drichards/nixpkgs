{ stdenv, fetchurl, cmake, bison, ncurses, openssl, readline, zlib, perl
, boost, cctools, CoreServices, developer_cmds }:

# Note: zlib is not required; MySQL can use an internal zlib.

let
self = stdenv.mkDerivation rec {
  name = "mysql-${version}";
  version = "5.7.20";

  src = fetchurl {
    url = "mirror://mysql/MySQL-5.7/${name}.tar.gz";
    sha256 = "11v4g3igigv3zvknv67qml8in6fjrbs2vnr3q6bg6f62nydm95sk";
  };

  preConfigure = stdenv.lib.optional stdenv.isDarwin ''
    ln -s /bin/ps $TMPDIR/ps
    export PATH=$PATH:$TMPDIR
  '';

  buildInputs = [ cmake bison ncurses openssl readline zlib boost ]
     ++ stdenv.lib.optionals stdenv.isDarwin [ perl cctools CoreServices developer_cmds ];

  enableParallelBuilding = true;

  cmakeFlags = [
    "-DWITH_SSL=yes"
    "-DWITH_READLINE=yes"
    "-DWITH_EMBEDDED_SERVER=yes"
    "-DWITH_ZLIB=yes"
    "-DHAVE_IPV6=yes"
    "-DMYSQL_UNIX_ADDR=/run/mysqld/mysqld.sock"
    "-DMYSQL_DATADIR=/var/lib/mysql"
    "-DINSTALL_SYSCONFDIR=etc/mysql"
    "-DINSTALL_INFODIR=share/mysql/docs"
    "-DINSTALL_MANDIR=share/man"
    "-DINSTALL_PLUGINDIR=lib/mysql/plugin"
    "-DINSTALL_SCRIPTDIR=bin"
    "-DINSTALL_INCLUDEDIR=include/mysql"
    "-DINSTALL_DOCREADMEDIR=share/mysql"
    "-DINSTALL_SUPPORTFILESDIR=share/mysql"
    "-DINSTALL_MYSQLSHAREDIR=share/mysql"
    "-DINSTALL_DOCDIR=share/mysql/docs"
    "-DINSTALL_SHAREDIR=share/mysql"
  ];

  NIX_LDFLAGS = stdenv.lib.optionalString stdenv.isLinux "-lgcc_s";

  prePatch = ''
    sed -i -e "s|/usr/bin/libtool|libtool|" cmake/libutils.cmake
  '';
  postInstall = ''
    sed -i -e "s|basedir=\"\"|basedir=\"$out\"|" $out/bin/mysql_install_db
    rm -r $out/mysql-test "$out"/lib/*.a
    rm $out/share/man/man1/mysql-test-run.pl.1
  '';

  passthru = {
    connector-c = self;
    mysqlVersion = "5.7";
  };

  meta = {
    homepage = http://www.mysql.com/;
    description = "The world's most popular open source database";
    platforms = stdenv.lib.platforms.unix;
  };
}; in self
