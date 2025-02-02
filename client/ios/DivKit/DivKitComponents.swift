import Foundation

import BasePublic
import BaseUIPublic
import LayoutKit
import NetworkingPublic
import Serialization

#if os(iOS)
import UIKit
#else
import AppKit
#endif

public final class DivKitComponents {
  public typealias UpdateCardAction = (NonEmptyArray<DivActionURLHandler.UpdateReason>) -> Void

  public let actionHandler: DivActionHandler
  public let blockStateStorage = DivBlockStateStorage()
  public let divCustomBlockFactory: DivCustomBlockFactory
  public var extensionHandlers: [DivExtensionHandler]
  public let flagsInfo: DivFlagsInfo
  public let fontProvider: DivFontProvider
  public let imageHolderFactory: ImageHolderFactory
  public let layoutDirection: UserInterfaceLayoutDirection
  public let patchProvider: DivPatchProvider
  public let playerFactory: PlayerFactory?
  public let safeAreaManager: DivSafeAreaManager
  public let stateManagement: DivStateManagement
  public let showToolip: DivActionURLHandler.ShowTooltipAction?
  public let tooltipManager: TooltipManager
  public let triggersStorage: DivTriggersStorage
  public let urlHandler: DivUrlHandler
  public let variablesStorage: DivVariablesStorage
  public let visibilityCounter = DivVisibilityCounter()
  public var updateCardSignal: Signal<[DivActionURLHandler.UpdateReason]> {
    updateCardPipe.signal
  }

  private let timerStorage: DivTimerStorage
  private let updateAggregator: RunLoopCardUpdateAggregator
  private let updateCard: DivActionURLHandler.UpdateCardAction
  private let variableTracker = DivVariableTracker()
  private let disposePool = AutodisposePool()
  private let updateCardPipe: SignalPipe<[DivActionURLHandler.UpdateReason]>
  private let persistentValuesStorage = DivPersistentValuesStorage()

  public init(
    divCustomBlockFactory: DivCustomBlockFactory = EmptyDivCustomBlockFactory(),
    extensionHandlers: [DivExtensionHandler] = [],
    flagsInfo: DivFlagsInfo = .default,
    fontProvider: DivFontProvider? = nil,
    imageHolderFactory: ImageHolderFactory? = nil,
    layoutDirection: UserInterfaceLayoutDirection = .leftToRight,
    patchProvider: DivPatchProvider? = nil,
    requestPerformer: URLRequestPerforming? = nil,
    showTooltip: DivActionURLHandler.ShowTooltipAction? = nil,
    stateManagement: DivStateManagement = DefaultDivStateManagement(),
    tooltipManager: TooltipManager? = nil,
    trackVisibility: @escaping DivActionHandler.TrackVisibility = { _, _ in },
    trackDisappear: @escaping DivActionHandler.TrackVisibility = { _, _ in },
    updateCardAction: UpdateCardAction? = nil, // remove in next major release
    playerFactory: PlayerFactory? = nil,
    urlHandler: DivUrlHandler? = nil,
    urlOpener: @escaping UrlOpener = { _ in }, // remove in next major release
    variablesStorage: DivVariablesStorage = DivVariablesStorage()
  ) {
    self.divCustomBlockFactory = divCustomBlockFactory
    self.extensionHandlers = extensionHandlers
    self.flagsInfo = flagsInfo
    self.fontProvider = fontProvider ?? DefaultFontProvider()
    self.layoutDirection = layoutDirection
    self.playerFactory = playerFactory ?? defaultPlayerFactory
    self.showToolip = showTooltip
    self.stateManagement = stateManagement
    let urlHandler = urlHandler ?? DivUrlHandlerDelegate(urlOpener)
    self.urlHandler = urlHandler
    self.variablesStorage = variablesStorage

    let updateCardActionSignalPipe = SignalPipe<[DivActionURLHandler.UpdateReason]>()
    self.updateCardPipe = updateCardActionSignalPipe

    safeAreaManager = DivSafeAreaManager(storage: variablesStorage)

    updateAggregator = RunLoopCardUpdateAggregator(updateCardAction: {
      updateCardAction?($0)
      updateCardActionSignalPipe.send($0.asArray())
    })
    updateCard = updateAggregator.aggregate(_:)

    let requestPerformer = requestPerformer ?? URLRequestPerformer(urlTransform: nil)

    self.imageHolderFactory = imageHolderFactory
      ?? makeImageHolderFactory(requestPerformer: requestPerformer)

    self.patchProvider = patchProvider
      ?? DivPatchDownloader(requestPerformer: requestPerformer)

    weak var weakTimerStorage: DivTimerStorage?
    weak var weakActionHandler: DivActionHandler?

    #if os(iOS)
    self.tooltipManager = tooltipManager ?? DefaultTooltipManager(
      shownTooltips: .init(),
      handleAction: {
        switch $0.payload {
        case let .divAction(params: params):
          weakActionHandler?.handle(params: params, sender: nil)
        default: break
        }
      }
    )
    #else
    self.tooltipManager = tooltipManager ?? DefaultTooltipManager()
    #endif

    actionHandler = DivActionHandler(
      stateUpdater: stateManagement,
      blockStateStorage: blockStateStorage,
      patchProvider: self.patchProvider,
      variablesStorage: variablesStorage,
      updateCard: updateCard,
      showTooltip: showTooltip,
      tooltipActionPerformer: self.tooltipManager,
      logger: DefaultDivActionLogger(
        requestPerformer: requestPerformer
      ),
      trackVisibility: trackVisibility,
      trackDisappear: trackDisappear,
      performTimerAction: { weakTimerStorage?.perform($0, $1, $2) },
      urlHandler: urlHandler,
      persistentValuesStorage: persistentValuesStorage
    )

    triggersStorage = DivTriggersStorage(
      variablesStorage: variablesStorage,
      actionHandler: actionHandler,
      persistentValuesStorage: persistentValuesStorage
    )

    timerStorage = DivTimerStorage(
      variablesStorage: variablesStorage,
      actionHandler: actionHandler,
      updateCard: updateCard,
      persistentValuesStorage: persistentValuesStorage
    )

    weakActionHandler = actionHandler
    weakTimerStorage = timerStorage

    variablesStorage.changeEvents.addObserver { [weak self] event in
      self?.onVariablesChanged(event: event)
    }.dispose(in: disposePool)
  }

  public func reset() {
    patchProvider.cancelRequests()

    blockStateStorage.reset()
    stateManagement.reset()
    variablesStorage.reset()
    visibilityCounter.reset()
    timerStorage.reset()
  }

  public func reset(cardId: DivCardID) {
    blockStateStorage.reset(cardId: cardId)
    stateManagement.reset(cardId: cardId)
    variablesStorage.reset(cardId: cardId)
    visibilityCounter.reset(cardId: cardId)
    timerStorage.reset(cardId: cardId)
  }

  public func parseDivData(
    _ jsonDict: [String: Any],
    cardId: DivCardID
  ) throws -> DeserializationResult<DivData> {
    try parseDivDataWithTemplates(["card": jsonDict], cardId: cardId)
  }

  /// Parses DivData from JSON in following format:
  /// {
  ///   "card": { ... },
  ///   "templates": { ... }
  /// }
  public func parseDivDataWithTemplates(
    _ jsonDict: [String: Any],
    cardId: DivCardID
  ) throws -> DeserializationResult<DivData> {
    let rawDivData = try RawDivData(dictionary: jsonDict)
    let result = DivData.resolve(
      card: rawDivData.card,
      templates: rawDivData.templates
    )
    if let divData = result.value {
      setVariablesAndTriggers(divData: divData, cardId: cardId)
      setTimers(divData: divData, cardId: cardId)
    }
    return result
  }

  /// Parses DivData from JSON in following format:
  /// {
  ///   "card": { ... },
  ///   "templates": { ... }
  /// }
  public func parseDivDataWithTemplates(
    _ jsonData: Data,
    cardId: DivCardID
  ) throws -> DeserializationResult<DivData> {
    guard let jsonObj = try? JSONSerialization.jsonObject(with: jsonData),
          let jsonDict = jsonObj as? [String: Any] else {
      throw DeserializationError.invalidJSONData(data: jsonData)
    }
    return try parseDivDataWithTemplates(jsonDict, cardId: cardId)
  }

  public func makeContext(
    cardId: DivCardID,
    cachedImageHolders: [ImageHolder],
    debugParams: DebugParams = DebugParams(),
    parentScrollView: ScrollView? = nil
  ) -> DivBlockModelingContext {
    variableTracker.onModelingStarted(cardId: cardId)
    return DivBlockModelingContext(
      cardId: cardId,
      stateManager: stateManagement.getStateManagerForCard(cardId: cardId),
      blockStateStorage: blockStateStorage,
      visibilityCounter: visibilityCounter,
      imageHolderFactory: imageHolderFactory
        .withInMemoryCache(cachedImageHolders: cachedImageHolders),
      divCustomBlockFactory: divCustomBlockFactory,
      fontProvider: fontProvider,
      flagsInfo: flagsInfo,
      extensionHandlers: extensionHandlers,
      variables: variablesStorage.makeVariables(for: cardId),
      playerFactory: playerFactory,
      debugParams: debugParams,
      parentScrollView: parentScrollView,
      layoutDirection: layoutDirection,
      variableTracker: variableTracker,
      persistentValuesStorage: persistentValuesStorage
    )
  }

  public func setVariablesAndTriggers(divData: DivData, cardId: DivCardID) {
    updateAggregator.performWithNoUpdates {
      let divDataVariables = divData.variables?.extractDivVariableValues() ?? [:]
      variablesStorage.append(
        variables: divDataVariables,
        for: cardId,
        replaceExisting: false
      )

      triggersStorage.set(
        cardId: cardId,
        triggers: divData.variableTriggers ?? []
      )
    }
  }

  public func setTimers(divData: DivData, cardId: DivCardID) {
    timerStorage.set(cardId: cardId, timers: divData.timers ?? [])
  }

  private func onVariablesChanged(event: DivVariablesStorage.ChangeEvent) {
    switch event.kind {
    case let .global(variables):
      let cardIds = variableTracker.getAffectedCards(variables: variables)
      if !cardIds.isEmpty {
        updateCard(.variable(.specific(cardIds)))
      }
    case let .local(cardId, _):
      updateCard(.variable(.specific([cardId])))
    }
  }
}

func makeImageHolderFactory(requestPerformer: URLRequestPerforming) -> ImageHolderFactory {
  ImageHolderFactory(
    requester: NetworkURLResourceRequester(
      performer: requestPerformer
    ),
    imageProcessingQueue: OperationQueue(
      name: "tech.divkit.image-processing",
      qos: .userInitiated
    )
  )
}

#if os(iOS)
let defaultPlayerFactory: PlayerFactory? = DefaultPlayerFactory()
#else
let defaultPlayerFactory: PlayerFactory? = nil
#endif
