//
//  SamidareView.swift
//  SamidareView
//
//  Created by Keisuke Kawamura on 2018/03/26.
//

import UIKit

open class SamidareView: UIView {

    public weak var dataSource: SamidareViewDataSource?
    public weak var delegate: SamidareViewDelegate?

    private(set) weak var scrollView: UIScrollView!
    private weak var contentView: UIView!
    private var contentViewWidthConstraint: NSLayoutConstraint!
    private var contentViewHeightConstraint: NSLayoutConstraint!
    private weak var eventStackView: UIStackView!

    private weak var editingView: EventView?
    private var editingViewTopConstraint: NSLayoutConstraint? {
        let constraint = editingView?.superview?.constraints.first(where: {
            guard let firstItem = $0.firstItem as? EventView else { return false }
            return $0.identifier == "EventViewTopConstraint" && firstItem == editingView
        })
        return constraint
    }
    private var editingViewHeightConstraint: NSLayoutConstraint? {
        let constraint = editingView?.constraints.first(where: {
            return $0.identifier == "EventViewHeightConstraint"
        })
        return constraint
    }
    private weak var editingTargetEventViewSnapshot: UIView?
    private weak var editingViewTopMarkArea: UIView?
    private weak var editingViewBottomMarkArea: UIView?

    private let editingTargetEventViewAlpha: CGFloat = 0.3
    private var lastTouchLocationInEditingEventView: CGPoint?
    private var handlingGestureRecognizer: UIGestureRecognizer?
    private var lastEditingType: TimeEditingType?
    private var lastLocationInSelf: CGPoint!
    private var autoScrollDisplayLink: CADisplayLink?
    private var autoScrollDisplayLinkLastTimeStamp: CFTimeInterval!
    private let autoScrollThreshold: CGFloat = 0.1   // max 1
    private let autoScrollMinSpeed: CGFloat = 50     // [point per frame]
    private let autoScrollMaxSpeed: CGFloat = 500    // [point per frame]

    private let impactFeedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let errorFeedbackGenerator = UINotificationFeedbackGenerator()

    internal let defaultWidthForColumn: CGFloat = 44
    internal let defaultHeightPerInterval: CGFloat = 10

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }

    private func commonInit() {

        let scrollView = UIScrollView()
        scrollView.bounces = true
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.isDirectionalLockEnabled = true
        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.topAnchor.constraint(equalTo: topAnchor).isActive = true
        scrollView.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
        scrollView.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        scrollView.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        self.scrollView = scrollView

        let contentView = UIView()
        contentView.backgroundColor = .clear
        scrollView.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.topAnchor.constraint(equalTo: scrollView.topAnchor).isActive = true
        contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor).isActive = true
        contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor).isActive = true
        contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor).isActive = true
        contentViewWidthConstraint = contentView.widthAnchor.constraint(equalToConstant: 0)
        contentViewWidthConstraint.isActive = true
        contentViewHeightConstraint = contentView.heightAnchor.constraint(equalToConstant: 0)
        contentViewHeightConstraint.isActive = true
        self.contentView = contentView

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(contentViewDidTap))
        contentView.addGestureRecognizer(tapGesture)

        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.distribution = .fillEqually
        stackView.spacing = 2
        contentView.addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.topAnchor.constraint(equalTo: contentView.topAnchor).isActive = true
        stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor).isActive = true
        stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor).isActive = true
        stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor).isActive = true
        self.eventStackView = stackView

        // for LongPress EventView
        impactFeedbackGenerator.prepare()
        errorFeedbackGenerator.prepare()
    }

    public func reload() {

        endEditingOfEventTime()
        layoutContentView()
        reloadStackView()
    }

    private func layoutContentView() {

        guard let dataSource = dataSource else { return }

        let numberOfColumns = dataSource.numberOfColumns(in: self)
        let numberOfIntervals = dataSource.timeRange(in: self).numberOfIntervals
        let widthForColumn = delegate?.widthForEventColumn(in: self) ?? defaultWidthForColumn
        let heightPerInterval = delegate?.heightPerMinInterval(in: self) ?? defaultHeightPerInterval

        contentViewWidthConstraint.constant = CGFloat(numberOfColumns) * widthForColumn
        contentViewHeightConstraint.constant = CGFloat(numberOfIntervals) * heightPerInterval
    }

    private func reloadStackView() {

        guard let dataSource = dataSource else { return }

        let timeRange = dataSource.timeRange(in: self)
        let heightPerInterval = delegate?.heightPerMinInterval(in: self) ?? defaultHeightPerInterval

        eventStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for column in 0 ..< dataSource.numberOfColumns(in: self) {

            let columnView = UIView()
            eventStackView.addArrangedSubview(columnView)

            for event in dataSource.events(in: self, inColumn: column) {

                let eventView = delegate?.eventView(in: self, inColumn: column, for: event) ?? EventView(event: event)
                columnView.addSubview(eventView)

                eventView.translatesAutoresizingMaskIntoConstraints = false
                eventView.leadingAnchor.constraint(equalTo: columnView.leadingAnchor).isActive = true
                eventView.trailingAnchor.constraint(equalTo: columnView.trailingAnchor).isActive = true

                let topInterval = (event.start.totalMinutes - timeRange.start.totalMinutes) / timeRange.minInterval
                let topConstraint = eventView.topAnchor.constraint(equalTo: columnView.topAnchor)
                topConstraint.identifier = "EventViewTopConstraint"
                topConstraint.constant = CGFloat(topInterval) * heightPerInterval
                topConstraint.isActive = true

                let numberOfIntervals = max((event.end.totalMinutes - event.start.totalMinutes) / timeRange.minInterval, 1)
                let heightConstraint = eventView.heightAnchor.constraint(equalToConstant: 0)
                heightConstraint.identifier = "EventViewHeightConstraint"
                heightConstraint.constant = CGFloat(numberOfIntervals) * heightPerInterval
                heightConstraint.isActive = true

                let tapGesture = UITapGestureRecognizer(target: self, action: #selector(eventViewDidTap))
                eventView.addGestureRecognizer(tapGesture)

                let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(eventViewDidLongPress))
                eventView.addGestureRecognizer(longPressGesture)
            }
        }
    }
}

// MARK: - Extension for Edit

extension SamidareView {

    // MARK: - Utils

    /// Translate to Time from y in contentView. Returned Time is rounded to nearest interval.
    private func translateToTime(fromYInContentView y: CGFloat) -> Time {

        guard let dataSource = dataSource else { fatalError() }

        let timeRange = dataSource.timeRange(in: self)
        let startMinutes = timeRange.start.totalMinutes
        let endMinutes = timeRange.end.totalMinutes
        let minInterval = timeRange.minInterval
        let totalHeight = contentViewHeightConstraint.constant
        let yRatio = y / totalHeight

        var minutes = Int(round(CGFloat(endMinutes - startMinutes) * yRatio)) + startMinutes
        let modulo = minutes % minInterval

        if modulo > 0 {
            if Float(modulo) / Float(minInterval) >= 0.5 {
                // ceil
                minutes -= modulo
                minutes += minInterval
            } else {
                // floor
                minutes = minutes / minInterval * minInterval
            }
        }

        let result = Time(hours: 0, minutes: minutes)
        return result
    }

    /// Translate to y in contentView from Time
    private func translateToYInContentView(from time: Time) -> CGFloat {

        guard let dataSource = dataSource else { fatalError() }
        let timeRange = dataSource.timeRange(in: self)
        let startMinutes = timeRange.start.totalMinutes
        let minInterval = timeRange.minInterval
        let heightPerInterval = delegate?.heightPerMinInterval(in: self) ?? defaultHeightPerInterval

        return CGFloat((time.totalMinutes - startMinutes) / minInterval) * heightPerInterval
    }

    // MARK: - ContentView Gesture Handlers

    @objc private func contentViewDidTap(_ sender: UITapGestureRecognizer) {

        if editingView != nil {
            endEditingOfEventTime()
        } else {

        }
    }

    // MARK: - EventView Gesture Handlers

    @objc private func eventViewDidTap(_ sender: UITapGestureRecognizer) {

        guard let tappedEventView = sender.view as? EventView else { fatalError() }

        if let editingView = editingView {
            if editingView != tappedEventView {
                endEditingOfEventTime()
            }
        } else {
            delegate?.eventViewDidTap(in: self, eventView: tappedEventView)
        }
    }

    @objc private func eventViewDidLongPress(_ sender: UILongPressGestureRecognizer) {

        guard let targetEventView = sender.view as? EventView else { return }

        handlingGestureRecognizer = sender

        switch sender.state {
        case .began:
            endEditingOfEventTime()

            //
            // Start editing if possible
            //
            if targetEventView.event.isEditable {
                beginEditingEvent(target: targetEventView)

                lastTouchLocationInEditingEventView = sender.location(in: editingView!)

                impactFeedbackGenerator.impactOccurred()
            } else {
                errorFeedbackGenerator.notificationOccurred(.error)
            }

        case .changed:
            if editingView != nil {
                // Move EditingEventView if EventView dragged after long press.
                handlePanningToEditTime(sender)
            }

        case .ended:
            if editingView != nil {
                handlePanningToEditTime(sender)
            }
            handlingGestureRecognizer = nil

        default:
            handlingGestureRecognizer = nil
        }
    }

    // MARK: - EditingView Gesture Handlers

    private func beginEditingEvent(target eventView: EventView) {

        guard let columnView = eventView.superview else { return }

        //
        // Begin EventView edit mode
        //
        let snapshot = eventView.snapshotView()
        snapshot.frame = eventView.frame
        snapshot.alpha = editingTargetEventViewAlpha
        columnView.insertSubview(snapshot, belowSubview: eventView)
        editingTargetEventViewSnapshot = snapshot

        editingView = eventView
        editingView!.isTimeViewsRightSide = columnView.frame.minX < editingView!.editingTimeView.bounds.width
        editingView!.beginEditing()
        columnView.bringSubview(toFront: editingView!)
        eventStackView.bringSubview(toFront: columnView)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanningToEditTime))
        editingView!.addGestureRecognizer(panGesture)

        //
        // Add Top Circle Mark Area to edit start time
        //
        let topMarkArea = EventView.createMarkAreaView(color: eventView.themeColor, isTop: true)
        contentView.addSubview(topMarkArea)
        topMarkArea.translatesAutoresizingMaskIntoConstraints = false
        topMarkArea.centerYAnchor.constraint(equalTo: editingView!.topAnchor).isActive = true
        topMarkArea.trailingAnchor.constraint(equalTo: editingView!.trailingAnchor).isActive = true
        editingViewTopMarkArea = topMarkArea
        let topPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanningToEditTime))
        topMarkArea.addGestureRecognizer(topPanGesture)

        //
        // Add Bottom Circle Mark Area to edit end time
        //
        let bottomMarkArea = EventView.createMarkAreaView(color: eventView.themeColor, isTop: false)
        contentView.addSubview(bottomMarkArea)
        bottomMarkArea.translatesAutoresizingMaskIntoConstraints = false
        bottomMarkArea.centerYAnchor.constraint(equalTo: editingView!.bottomAnchor).isActive = true
        bottomMarkArea.leadingAnchor.constraint(equalTo: editingView!.leadingAnchor).isActive = true
        editingViewBottomMarkArea = bottomMarkArea
        let bottomPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanningToEditTime))
        bottomMarkArea.addGestureRecognizer(bottomPanGesture)
    }

    @objc private func handlePanningToEditTime(_ sender: UIGestureRecognizer) {

        guard let senderView = sender.view else { fatalError() }
        guard let editingView = editingView else { fatalError() } // FIXME: - ここで落ちるときがあったが再現できない…
        guard let topMarkArea = editingViewTopMarkArea else { fatalError() }
        guard let bottomMarkArea = editingViewBottomMarkArea else { fatalError() }

        handlingGestureRecognizer = sender

        switch sender.state {
        case .began:
            lastTouchLocationInEditingEventView = sender.location(in: editingView)

        case .changed:
            lastLocationInSelf = sender.location(in: self)
            autoScrollIfNeeded()

            switch senderView {
            case editingView:
                updateEditingViewFrame(type: .both)

            case topMarkArea:
                updateEditingViewFrame(type: .startOnly)

            case bottomMarkArea:
                updateEditingViewFrame(type: .endOnly)

            default:
                break
            }

        case .ended:
            invalidateAutoScrollDisplayLink()
            decideEditingOfEventTime()
            handlingGestureRecognizer = nil

        default:
            handlingGestureRecognizer = nil
        }
    }

    // MARK: - Moving of EditingEventView

    private enum TimeEditingType {
        case both
        case startOnly
        case endOnly
    }

    /// for moving by PanGesture on EditingEventView or LongPressGesture on EventView
    private func updateEditingViewFrame(type: TimeEditingType = .both) {

        guard let dataSource = dataSource else { fatalError() }
        let timeRange = dataSource.timeRange(in: self)
        guard let editingView = editingView else { fatalError() }
        guard let topConstraint = editingViewTopConstraint else { fatalError() }
        guard let heightConstraint = editingViewHeightConstraint else { fatalError() }
        guard let targetEventViewSnapshot = editingTargetEventViewSnapshot else { fatalError() }
        guard let recognizer = handlingGestureRecognizer else { fatalError() }
        guard let lastTouchLocation = lastTouchLocationInEditingEventView else { fatalError() }

        lastEditingType = type

        let heightPerMinInterval = delegate?.heightPerMinInterval(in: self) ?? defaultHeightPerInterval
        let locationInContentView = recognizer.location(in: contentView)
        let editingViewHeight = editingView.bounds.height

        // Calculate estimeated editingView position y
        var estimatedTopY: CGFloat = {
            switch type {
            case .both, .startOnly: return locationInContentView.y - lastTouchLocation.y
            case .endOnly:          return targetEventViewSnapshot.frame.minY
            }
        }()
        var estimatedBottomY: CGFloat = {
            switch type {
            case .both:         return estimatedTopY + editingViewHeight
            case .startOnly:    return targetEventViewSnapshot.frame.maxY
            case .endOnly:
                let simulatedTopY = locationInContentView.y - lastTouchLocation.y
                let movedLength = targetEventViewSnapshot.frame.minY - simulatedTopY
                return targetEventViewSnapshot.frame.maxY - movedLength
            }
        }()

        // Restrict EditingView position to TimeRange
        let minTopY = translateToYInContentView(from: timeRange.start)
        let maxTopY = translateToYInContentView(from: timeRange.end) - (estimatedBottomY - estimatedTopY)
        let maxBottomY = translateToYInContentView(from: timeRange.end)

        switch type {
        case .both:
            estimatedTopY = max(estimatedTopY, minTopY)
            estimatedTopY = min(estimatedTopY, maxTopY)
        case .startOnly:
            estimatedTopY = max(estimatedTopY, minTopY)
        case .endOnly:
            estimatedBottomY = min(estimatedBottomY, maxBottomY)
        }

        // Restrict to minimum interval or more
        if type == .startOnly {
            estimatedTopY = min(estimatedTopY, estimatedBottomY - heightPerMinInterval)
        } else if type == .endOnly {
            estimatedBottomY = max(estimatedBottomY, estimatedTopY + heightPerMinInterval)
        }

        if type == .both {
            estimatedBottomY = estimatedTopY + editingViewHeight
        }

        // Recalucate event time range
        let decidedTopY = estimatedTopY
        let decidedBottomY = estimatedBottomY
        let editingStartTime = translateToTime(fromYInContentView: decidedTopY)
        let editingEndTime = translateToTime(fromYInContentView: decidedBottomY)

        // Apply decided Y and event time range
        topConstraint.constant = decidedTopY
        heightConstraint.constant = decidedBottomY - decidedTopY
        editingView.updateTimesInEditing(start: editingStartTime, end: editingEndTime)
    }

    private func alignEditingViewFrameToNearestInterval() {

        guard let editingView = editingView else { fatalError() }
        guard let topConstraint = editingViewTopConstraint else { fatalError() }
        guard let heightConstraint = editingViewHeightConstraint else { fatalError() }

        let alignedTopY = translateToYInContentView(from: editingView.startTimeInEditing)
        let alignedBottomY = translateToYInContentView(from: editingView.endTimeInEditing)

        topConstraint.constant = alignedTopY
        heightConstraint.constant = alignedBottomY - alignedTopY

        UIView.animate(withDuration: 0.1, animations: {
            // Also animate top mark and bottom mark
            self.contentView.layoutIfNeeded()
        })
    }

    private func decideEditingOfEventTime() {

        guard let editingView = editingView else { fatalError() }
        guard let oldSnapshot = editingTargetEventViewSnapshot else { fatalError() }
        guard let columnView = editingView.superview else { fatalError() }

        alignEditingViewFrameToNearestInterval()

        let oldEvent = editingView.event
        let newEvent = Event(id: oldEvent.id,
                             title: oldEvent.title,
                             start: editingView.startTimeInEditing,
                             end: editingView.endTimeInEditing)

        let y = translateToYInContentView(from: newEvent.start)
        let height = translateToYInContentView(from: newEvent.end) - y

        let newSnapshot = editingView.snapshotView()
        newSnapshot.frame = CGRect(x: 0, y: y,
                                   width: oldSnapshot.frame.width, height: height)
        newSnapshot.alpha = 0
        columnView.insertSubview(newSnapshot, belowSubview: editingView)
        editingTargetEventViewSnapshot = newSnapshot

        UIView.animate(withDuration: 0.1, animations: {
            oldSnapshot.alpha = 0
            newSnapshot.alpha = self.editingTargetEventViewAlpha
        }, completion: { _ in
            oldSnapshot.removeFromSuperview()
        })

        impactFeedbackGenerator.impactOccurred()

        if oldEvent.start != newEvent.start || oldEvent.end != newEvent.end {
            editingView.applyTimesInEditing()
            delegate?.eventDidEdit(in: self, newEvent: newEvent, oldEvent: oldEvent)
        }
    }

    private func endEditingOfEventTime() {

        guard let editingView = editingView else { return }
        let columnView = editingView.superview!

        editingView.endEditing()
        let panGesture = editingView.gestureRecognizers!.first(where: { $0 is UIPanGestureRecognizer })!
        editingView.removeGestureRecognizer(panGesture)

        // Adjust EventView z-orders. Shortest event should be frontmost. Longest event should be backmost.
        let sortedViews = columnView.subviews.sorted(by: {
            guard let eventView1 = $0 as? EventView, let eventView2 = $1 as? EventView else { return false }
            let duration1 = eventView1.event.end.totalMinutes - eventView1.event.start.totalMinutes
            let duration2 = eventView2.event.end.totalMinutes - eventView2.event.start.totalMinutes
            return duration1 > duration2
        })
        for view in sortedViews {
            columnView.bringSubview(toFront: view)
        }

        self.editingView = nil
        editingViewTopMarkArea?.removeFromSuperview()
        editingViewBottomMarkArea?.removeFromSuperview()
        editingTargetEventViewSnapshot?.removeFromSuperview()
        editingViewTopMarkArea = nil
        editingViewBottomMarkArea = nil
        editingTargetEventViewSnapshot = nil
    }

    // MARK: - Auto Scroll

    private func shouldAutoScroll() -> (should: Bool, strength: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat)) {

        var returnedValue: (should: Bool, strength: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat)) = (false, (0, 0, 0, 0))

        guard let location = lastLocationInSelf else { return returnedValue }

        let yRate = location.y / bounds.height
        let xRate = location.x / bounds.width
        let top = yRate <= autoScrollThreshold
        let left = xRate <= autoScrollThreshold
        let bottom = yRate >= (1 - autoScrollThreshold)
        let right = xRate >= (1 - autoScrollThreshold)
        // Strength = 1 - Rate / Threshold (if top or left)
        // Strength = (Rate - Threshold) * 10 (if bottom or right)
        returnedValue.strength.top = top ? min(1 - yRate / autoScrollThreshold, 1) : 0
        returnedValue.strength.left = left ? min(1 - xRate / autoScrollThreshold, 1) : 0
        returnedValue.strength.bottom = bottom ? min((yRate - (1 - autoScrollThreshold)) * 10, 1) : 0
        returnedValue.strength.right = right ? min((xRate / (1 - autoScrollThreshold)) * 10, 1) : 0
        returnedValue.should = top || left || bottom || right

        return returnedValue
    }

    private func autoScrollIfNeeded() {

        if shouldAutoScroll().should {
            if autoScrollDisplayLink == nil {
                autoScrollDisplayLink = CADisplayLink(target: self, selector: #selector(handleAutoScrollDisplayLink))
                autoScrollDisplayLink!.add(to: .main, forMode: .defaultRunLoopMode)
            }
        } else {
            invalidateAutoScrollDisplayLink()
        }
    }

    private func invalidateAutoScrollDisplayLink() {

        autoScrollDisplayLink?.invalidate()
        autoScrollDisplayLink = nil
        autoScrollDisplayLinkLastTimeStamp = nil
    }

    @objc private func handleAutoScrollDisplayLink(_ displayLink: CADisplayLink) {

        let shouldScroll = shouldAutoScroll()

        guard shouldScroll.should else { invalidateAutoScrollDisplayLink(); return }

        if let lastTime = autoScrollDisplayLinkLastTimeStamp {

            let deltaTime = displayLink.timestamp - lastTime
            let minSpeed = autoScrollMinSpeed
            let maxSpeed = autoScrollMaxSpeed
            let minContentOffsetY = -scrollView.contentInset.top
//            let minContentOffsetX = -scrollView.contentInset.left
            let maxContentOffsetY = scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom
//            let maxContentOffsetX = scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right

            if shouldScroll.strength.top > 0 {
                let strength = shouldScroll.strength.top
                let velocity = -1 * ((maxSpeed - minSpeed) * strength + minSpeed) * CGFloat(deltaTime)
                scrollView.contentOffset.y += velocity
                scrollView.contentOffset.y = max(scrollView.contentOffset.y, minContentOffsetY)
            } else if shouldScroll.strength.bottom > 0 {
                let strength = shouldScroll.strength.bottom
                let velocity = ((maxSpeed - minSpeed) * strength + minSpeed) * CGFloat(deltaTime)
                scrollView.contentOffset.y += velocity
                scrollView.contentOffset.y = min(scrollView.contentOffset.y, maxContentOffsetY)
            }
// Not support yet
//            if shouldScroll.strength.left > 0 {
//                let strength = shouldScroll.strength.left
//                let velocity = -1 * ((maxSpeed - minSpeed) * strength + minSpeed) * CGFloat(deltaTime)
//                scrollView.contentOffset.x += velocity
//                scrollView.contentOffset.x = max(scrollView.contentOffset.x, minContentOffsetX)
//            } else if shouldScroll.strength.right > 0 {
//                let strength = shouldScroll.strength.right
//                let velocity = ((maxSpeed - minSpeed) * strength + minSpeed) * CGFloat(deltaTime)
//                scrollView.contentOffset.x += velocity
//                scrollView.contentOffset.x = min(scrollView.contentOffset.x, maxContentOffsetX)
//            }

            updateEditingViewFrame(type: lastEditingType!)
        }

        autoScrollDisplayLinkLastTimeStamp = displayLink.timestamp
    }
}

// MARK: - Memo

//
// View Hierarchy
// self
//  - scrollView: UIScrollView
//      - contentView: UIView
//          - eventStackView: UIStackView
//

