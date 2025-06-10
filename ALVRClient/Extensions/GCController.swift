import GameController

extension GCController {
    class func spatialControllers() -> [GCController] {
        if #available(visionOS 26.0, *) {
#if XCODE_BETA_26
            print(GCController.controllers().map({ $0.productCategory}))
            return GCController.controllers().filter { $0.productCategory == GCProductCategorySpatialController }
#else
            return []
#endif
        }
        else {
            return []
        }
    }
}
