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

    private weak var editingView: EditingEventView?
    private var lastTouchLocationInEditingEventView: CGPoint?
    private var handlingGestureRecognizer: UIGestureRecognizer?
    private var lastLocationInSelf: CGPoint!
    private var autoScrollDisplayLink: CADisplayLink?
    private var autoScrollDisplayLinkLastTimeStamp: CFTimeInterval!
    private let autoScrollThreshold: CGFloat = 0.1   // max 1
    private let autoScrollMinSpeed: CGFloat = 50     // [point per frame]
    private let autoScrollMaxSpeed: CGFloat = 1000    // [point per frame]

    private var impactFeedbackGenerator: UIImpactFeedbackGenerator!

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
        contentView.addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.topAnchor.constraint(equalTo: contentView.topAnchor).isActive = true
        stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor).isActive = true
        stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor).isActive = true
        stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor).isActive = true
        self.eventStackView = stackView

        // for LongPress EventView
        impactFeedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)
        impactFeedbackGenerator.prepare()
    }

    public func reload() {

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

                let duration = (event.end.totalMinutes - event.start.totalMinutes) / timeRange.minInterval
                let heightConstraint = eventView.heightAnchor.constraint(equalToConstant: 0)
                heightConstraint.constant = CGFloat(duration) * heightPerInterval
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

        guard let editingView = editingView else { return }
        guard let targetEventView = editingView.targetEventView else { return }
        print("👿Edit Ended")
//        let topConstraint = targetEventView.constraints.first(where: { $0.identifier == "EventViewTopConstraint" })!

//        topConstraint.constant
        print(editingView.targetEventView.constraints)
    }

    // MARK: - EventView Gesture Handlers

    @objc private func eventViewDidTap(_ sender: UITapGestureRecognizer) {

        print("🎉")
    }

    @objc private func eventViewDidLongPress(_ sender: UILongPressGestureRecognizer) {

        guard let targetEventView = sender.view as? EventView else { return }

        handlingGestureRecognizer = sender

        switch sender.state {
        case .began:

            let locationInEventView = sender.location(in: targetEventView)
            lastTouchLocationInEditingEventView = locationInEventView

            //
            self.editingView?.removeFromSuperview()

            let eventViewFrameInContentView = targetEventView.convert(targetEventView.bounds, to: contentView)
            let editingView = EditingEventView(targetEventView: targetEventView)
            editingView.frame = eventViewFrameInContentView
            contentView.addSubview(editingView)
            self.editingView = editingView

            let panGesture = UIPanGestureRecognizer(target: self, action: #selector(editingViewDidPan))
            editingView.addGestureRecognizer(panGesture)

            targetEventView.alpha = 0.2

            impactFeedbackGenerator.impactOccurred()

        case .changed:
            // Move EditingEventView if EventView dragged after long press.
            lastLocationInSelf = sender.location(in: self)
            autoScrollIfNeeded()
            updateEditingViewFrame()

        case .ended:
            invalidateAutoScrollDisplayLink()
            handlingGestureRecognizer = nil
            alignEditingViewFrameToNearestInterval()

        default:
            break
        }
    }

    // MARK: - EditingView Gesture Handlers

    @objc private func editingViewDidPan(_ sender: UIPanGestureRecognizer) {

        guard let targetEditView = sender.view as? EditingEventView else { return }

        handlingGestureRecognizer = sender

        switch sender.state {
        case .began:
            let locationInEditView = sender.location(in: targetEditView)
            lastTouchLocationInEditingEventView = locationInEditView

        case .changed:
            lastLocationInSelf = sender.location(in: self)
            autoScrollIfNeeded()
            updateEditingViewFrame()

        case .ended:
            invalidateAutoScrollDisplayLink()
            handlingGestureRecognizer = nil
            alignEditingViewFrameToNearestInterval()

        default:
            break
        }
    }

    /// for moving by PanGesture on EditingEventView or LongPressGesture on EventView
    private func updateEditingViewFrame() {

        guard let dataSource = dataSource else { fatalError() }
        let timeRange = dataSource.timeRange(in: self)
        guard let editingView = editingView else { return }
        guard let recognizer = handlingGestureRecognizer else { return }
        guard let lastTouchLocation = lastTouchLocationInEditingEventView else { return }

        let locationInContentView = recognizer.location(in: contentView)
        let editingViewHeight = editingView.bounds.height

        // Calculate estimeated editingView position y and event time range
        var estimatedY = locationInContentView.y - lastTouchLocation.y

        // Restrict EditingView position to TimeRange
        let minY = translateToYInContentView(from: timeRange.start)
        let maxY = translateToYInContentView(from: timeRange.end) - editingViewHeight
        estimatedY = max(estimatedY, minY)
        estimatedY = min(estimatedY, maxY)

        // Recalucate event time range
        let decidedY = estimatedY
        let editingStartTime = translateToTime(fromYInContentView: decidedY)
        let editingEndTime = translateToTime(fromYInContentView: decidedY + editingViewHeight)

        // Apply decided Y and event time range
        editingView.frame.origin.y = decidedY
        editingView.updateTimesInEditing(start: editingStartTime, end: editingEndTime)
    }

    private func alignEditingViewFrameToNearestInterval() {

        guard let editingView = editingView else { fatalError() }

        let currentY = editingView.frame.origin.y
        let roundedStartTime = translateToTime(fromYInContentView: currentY)
        let alignedY = translateToYInContentView(from: roundedStartTime)

        UIView.animate(withDuration: 0.1, animations: {
            editingView.frame.origin.y = alignedY
        })
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

            updateEditingViewFrame()
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

