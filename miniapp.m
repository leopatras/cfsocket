#import  <UIKit/UIKit.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#import  <CFNetwork/CFSocketStream.h>
@interface MyConnection: NSObject<NSStreamDelegate>
{
  //write relate members
  bool _outReady;
  NSOutputStream* _oStream;
  bool _hasSpaceAvail;
  //read related members
  NSInputStream* _iStream;
  bool _inReady;
}
@property(readonly) NSInputStream* iStream;
@end
@interface MyTCPServer: NSObject
{
  CFSocketRef _socket;
}
@property(readonly) int port;
- (MyConnection*)allocConnection;
@end

@implementation MyConnection
static void streamOpen(NSStream* stream,NSObject<NSStreamDelegate>* delegate)
{
  stream.delegate = delegate;
  [stream scheduleInRunLoop :[NSRunLoop currentRunLoop] forMode : NSRunLoopCommonModes];
  [stream open];
}

static void streamClose(NSStream* stream)
{
  [stream close];
  [stream removeFromRunLoop :[NSRunLoop currentRunLoop] forMode : NSRunLoopCommonModes];
  [stream setDelegate:nil];
}

- (id)initWithIn:(NSInputStream*)nsin andOut:(NSOutputStream*)nsout
{
  self = [super init];
  if (self==nil) { return nil;}
  _iStream=nsin;
  streamOpen(_iStream,self);
  _oStream=nsout;
  streamOpen(_oStream,self);
  return self;
}

-(void) dealloc
{
  streamClose(_oStream);
  streamClose(_iStream);
}
@end

static void createClientConnectionInt(CFSocketNativeHandle sock,MyConnection* conn) {
  int flag = 1;
  setsockopt(sock, IPPROTO_TCP, TCP_NODELAY,(char *)&flag, sizeof(int));
  CFReadStreamRef readStream = NULL;
  CFWriteStreamRef writeStream = NULL;
  CFStreamCreatePairWithSocket( kCFAllocatorDefault, sock, &readStream, &writeStream );
  
  if( readStream && writeStream ) {
    CFReadStreamSetProperty( readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue );
    CFWriteStreamSetProperty( writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue );
    conn=[conn initWithIn:(__bridge NSInputStream *)(readStream)
                   andOut:(__bridge NSOutputStream*)writeStream];
  } else {
    NSLog(@"Stream error");
    //destroy native socket
    close( sock );
  }
}

static NSMutableArray* s_con_arr=nil;
static int findIdx(NSInputStream* iStream) {
  int i=0;
  for (MyConnection *conn in s_con_arr) {
    if (conn.iStream==iStream) {
      return i;
    }
    i++;
  }
  return -1;
}
static void AcceptCallBack(CFSocketRef accsock, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
{
  if( type == kCFSocketAcceptCallBack ) {
    CFSocketNativeHandle sock = *(CFSocketNativeHandle*) data;
    MyTCPServer* srv=(__bridge MyTCPServer*)info;
    if (s_con_arr==nil) {
      s_con_arr=[NSMutableArray array];
    }
    MyConnection* conn=[srv allocConnection];
    [s_con_arr addObject:conn];
    createClientConnectionInt(sock,conn);
  }
}

@implementation MyTCPServer
- (id)init
{
  self = [super init];
  return self;
}

- (void)stop
{
  if( _socket ) {
    CFSocketInvalidate( _socket );
    CFRelease( _socket );
  }
  _socket = NULL;
}

- (void)dealloc
{
  [self stop];
}

- (MyConnection*)allocConnection
{
  return [MyConnection alloc];
}

- (bool)start
{
  CFSocketContext context = {0, (__bridge void *)(self), NULL, NULL, NULL};
  _socket = CFSocketCreate( kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP, kCFSocketAcceptCallBack, ( CFSocketCallBack ) &AcceptCallBack, &context );
  if (_socket == NULL) {
    NSLog(@"no socket");
    return false;
  }
  NSInteger extport = 9100;
  int opt = 1;
  setsockopt( CFSocketGetNative( _socket ), SOL_SOCKET, SO_REUSEADDR, (void*) &opt, sizeof ( opt ) );
  struct sockaddr_in saddr;
  memset( &saddr, 0, sizeof ( saddr ) );
  saddr.sin_len = sizeof ( saddr );
  saddr.sin_family = AF_INET;
  saddr.sin_port = htons(extport);
  saddr.sin_addr.s_addr = htonl( INADDR_ANY );
  NSData* naddr = [NSData dataWithBytes : &saddr length : sizeof ( saddr )];
  if( CFSocketSetAddress( _socket, (__bridge CFDataRef) naddr ) != kCFSocketSuccess) {
      NSLog(@"can't bind port");
      [self stop];
      return false;
  }
    /*
    else {
      NSData *addr = (__bridge NSData *)(CFSocketCopyAddress(_socket));
      memcpy(&saddr, [addr bytes], [addr length]);
      int actualport=ntohs(saddr.sin_port);
    }*/
  //set up the run loop source for the socket
  CFRunLoopRef cfrl = CFRunLoopGetCurrent();
  CFRunLoopSourceRef rlsource = CFSocketCreateRunLoopSource( kCFAllocatorDefault, _socket, 0 );
  CFRunLoopAddSource( cfrl, rlsource, kCFRunLoopCommonModes );
  CFRelease( rlsource );
  return true;
}
@end

@implementation MyConnection (NSStreamDelegate)
- (void) stream:(NSStream *)stream handleEvent:(NSStreamEvent)eventCode
{
  @try {
    [self stream:stream handleEventInt:eventCode];
  } @catch (NSException *exception) {
    NSLog(@"exception:%@",exception);
  }
}

- (void) stream:(NSStream *)stream handleEventInt:(NSStreamEvent)eventCode
{
  switch( eventCode )
  {
    case NSStreamEventOpenCompleted: {
      if( stream == _iStream ) {
        _inReady = true;
      } else if (stream == _oStream) {
        _outReady = true;
      }
      break;
    }
    case NSStreamEventHasSpaceAvailable: {
      assert( stream == _oStream );
      _hasSpaceAvail = true;
      NSLog(@"NSStreamEventHasSpaceAvailable");
      break;
    }
    case NSStreamEventHasBytesAvailable: {
      assert( stream == _iStream );
      uint8_t bytes[8192];
      NSInteger len = [_iStream read : bytes maxLength : 8192];
      NSLog(@"did read from source len:%ld",(long)len);
      break;
    }
    case NSStreamEventErrorOccurred: {
      NSError *e = [stream streamError];
      NSLog(@"%@",
            [NSString stringWithFormat:@"NSStreamEventErrorOcurred Error %d: %@",
             (int)[e code],[e localizedDescription]]);
      break;
    }
    case NSStreamEventEndEncountered: {
      NSLog(@"NSStreamEventEndEncountered");
      assert(stream==_iStream);
      int idx=findIdx(_iStream);
      if (idx!=-1) {
        [s_con_arr removeObjectAtIndex:idx];
      }
      break;
    }
    case NSStreamEventNone: {
      NSLog(@"NSStreamEventNone");
      break;
    }
  }
}
@end

@interface MyAppDelegate : UIResponder <UIApplicationDelegate>
{
  UIWindow* _win;
}
@end
static MyTCPServer* serv=nil;
static void checkTcpServer()
{
  if (serv==nil) {
    serv=[[MyTCPServer alloc] init];
    [serv start];
  }
}

@implementation MyAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  _win=[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
  _win.backgroundColor=UIColor.whiteColor;
  UIViewController* c=[[UIViewController alloc] init];
  UINavigationController* nav=[[UINavigationController alloc] initWithRootViewController:c];
  c.navigationItem.title=@"A title";
  NSMutableArray* arr=[NSMutableArray array];
  for(int i=0;i<4;i++) {
    NSString* s=[NSString stringWithFormat:@"Command%d",i];
    UIBarButtonItem* b=[[UIBarButtonItem alloc] initWithTitle:s style:UIBarButtonItemStylePlain target:self action:@selector(itemSelected:)];
    [arr insertObject:b atIndex:0];
  }
  c.navigationItem.rightBarButtonItems=arr;
  _win.rootViewController=nav;
  checkTcpServer();
  [_win makeKeyAndVisible];
  return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
  checkTcpServer();
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
  [serv stop];
  serv=nil;
}

-(void)itemSelected: (id)button
{
  NSLog(@"selected:%@",((NSObject*)button).description);
}
@end

int main(int argc, char * argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([MyAppDelegate class]));
  }
}
