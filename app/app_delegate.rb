class AppDelegate
  def application(application, didFinishLaunchingWithOptions:launchOptions)
    rootViewController = UIViewController.alloc.init
    rootViewController.title = 'dfimage_test'
    rootViewController.view.backgroundColor = UIColor.whiteColor

    navigationController = UINavigationController.alloc.initWithRootViewController(rootViewController)

    @window = UIWindow.alloc.initWithFrame(UIScreen.mainScreen.bounds)
    @window.rootViewController = navigationController
    @window.makeKeyAndVisible

    request = DFImageRequest.alloc.initWithResource(NSURL.URLWithString("http://assets.worldwildlife.org/photos/1620/images/carousel_small/bengal-tiger-why-matter_7341043.jpg"), targetSize:CGSizeMake(100,100), contentMode: DFImageContentModeAspectFill, options:nil)
    @compositeImageTask = DFCompositeImageTask.compositeImageTaskWithRequests([request], imageHandler: nil, completionHandler:nil)

    true
  end
end
