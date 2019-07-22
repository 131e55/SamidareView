//
//  EditingOverlayView.swift
//  Samidare
//
//  Created by Keisuke Kawamura on 2018/10/27.
//

import UIKit

/// EditingOverlayView manages its own layout constraints by itself.
internal class EditingOverlayView: TouchPassedView {

    private static let nib: UINib = UINib(nibName: "EditingOverlayView", bundle: Bundle(for: EditingOverlayView.self))
    /// Apply the constraint after move to superview. Until then it is nil.
    private weak var topConstraint: NSLayoutConstraint!
    /// Apply the constraint after move to superview. Until then it is nil.
    private weak var bottomConstraint: NSLayoutConstraint!
    @IBOutlet private weak var cellWidthConstraint: NSLayoutConstraint!
    @IBOutlet private weak var cellHeightConstraint: NSLayoutConstraint!
    @IBOutlet private weak var cellOverlayView: UIView!
    @IBOutlet private weak var leftTimeArea: UIView!
    @IBOutlet private weak var rightTimeArea: UIView!
    private var timeRangeView: TimeRangeView = TimeRangeView()
    @IBOutlet private weak var topKnobView: UIView!
    @IBOutlet private weak var bottomKnobView: UIView!

    private var editingCell: EventCell!
    
    private var cellPanGestureRecognizer: UIPanGestureRecognizer!
    private var topKnobPanGestureRecognizer: UIPanGestureRecognizer!
    private var bottomKnobPanGestureRecognizer: UIPanGestureRecognizer!

    /// First touch location in referencing EventScrollView.
    /// It's reset each time any gesture recognized.
    private var firstTouchLocation: CGPoint!
    /// Last touch location in referencing EventScrollView.
    private var lastTouchLocation: CGPoint!
    
    /// Current PanningPoint (cell or topKnob or bottomKnob)
    private var currentPanningPoint: PanningPoint? {
        didSet {
            switch currentPanningPoint {
            case .none:
                cellPanGestureRecognizer.isEnabled = true
                topKnobPanGestureRecognizer.isEnabled = true
                bottomKnobPanGestureRecognizer.isEnabled = true
            case .some(.cell):
                topKnobPanGestureRecognizer.isEnabled = false
                bottomKnobPanGestureRecognizer.isEnabled = false
            case .some(.topKnob):
                cellPanGestureRecognizer.isEnabled = false
                bottomKnobPanGestureRecognizer.isEnabled = false
            case .some(.bottomKnob):
                cellPanGestureRecognizer.isEnabled = false
                topKnobPanGestureRecognizer.isEnabled = false
            }
        }
    }

    /// Tells that begin panning cell or top-bottom knobs.
    internal var willPanHandler: ((_ panningPoint: PanningPoint) -> Void)?
    /// Tells that cell scaled by top-bottom knobs.
    /// If length is positive, means bottom side.
    /// If length is negative, means top side.
    internal var didPanKnobHandler: ((_ panningPoint: PanningPoint, _ length: CGFloat) -> Void)?
    /// Tells that cell moved by cell panning.
    /// If length is positive, cell.frame will be move bottom side.
    /// If length is negative, cell.frame will be move top side.
    internal var didPanCellHandler: ((_ length: CGFloat) -> Void)?
    /// Tells that ended panning cell or top-bottom knobs.
    internal var didEndPanningHandler: ((_ panningPoint: PanningPoint) -> Void)?

    internal var timeInfoWidth: CGFloat {
        return timeRangeView.intrinsicContentSize.width + 8 * 2
    }
    
    /// - Parameter cell: Editing target EventCell
    init(cell: EventCell) {
        super.init(frame: .zero)
        
        editingCell = cell
        isUserInteractionEnabled = true
        translatesAutoresizingMaskIntoConstraints = false

        let view = type(of: self).nib.instantiate(withOwner: self, options: nil).first as! UIView
        addSubview(view)
        view.activateFitFrameConstarintsToSuperview()

        cellPanGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(didPanCellOverlayView))
        cellOverlayView.addGestureRecognizer(cellPanGestureRecognizer)
        topKnobPanGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(didPanKnobView))
        topKnobView.addGestureRecognizer(topKnobPanGestureRecognizer)
        bottomKnobPanGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(didPanKnobView))
        bottomKnobView.addGestureRecognizer(bottomKnobPanGestureRecognizer)

        NotificationCenter.default.addObserver(self, selector: #selector(eventCellDidSetEvent),
                                               name: EventCell.didSetEventNotification, object: nil)
        setTimeRangeViewPosition(toRight: false)
        updateTimeLabels()
    }
    required public init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func didMoveToSuperview() {
        super.didMoveToSuperview()

        if superview != nil {
            setupLayoutConstraints()
        }
    }

    private func setupLayoutConstraints() {
        guard superview != nil else { fatalError("Call in didMoveToSuperview.") }

        topConstraint = topAnchor.constraint(equalTo: editingCell.topAnchor,
                                             constant: -topKnobView.bounds.height / 2)
        bottomConstraint = bottomAnchor.constraint(equalTo: editingCell.bottomAnchor,
                                                   constant: bottomKnobView.bounds.height / 2)
        // left and right timeRangeView width.
        let additionalWidth = timeInfoWidth * 2

        NSLayoutConstraint.activate([
            topConstraint,
            bottomConstraint,
            centerXAnchor.constraint(equalTo: editingCell.centerXAnchor),
            widthAnchor.constraint(equalTo: editingCell.widthAnchor, constant: additionalWidth),
            cellOverlayView.widthAnchor.constraint(equalTo: editingCell.widthAnchor),
            cellOverlayView.heightAnchor.constraint(equalTo: editingCell.heightAnchor)
        ])
    }
    
    internal func setTimeRangeViewPosition(toRight: Bool) {
        if toRight && timeRangeView.superview != rightTimeArea {
            rightTimeArea.addSubview(timeRangeView)
            timeRangeView.activateFitFrameConstarintsToSuperview()
        } else if toRight == false && timeRangeView.superview != leftTimeArea {
            leftTimeArea.addSubview(timeRangeView)
            timeRangeView.activateFitFrameConstarintsToSuperview()
        }
    }
    
    private func updateTimeLabels() {
        guard let cell = editingCell else { return }
        timeRangeView.update(timeRange: cell.event.start ... cell.event.end)
    }

    @objc private func didPanCellOverlayView(_ sender: UIGestureRecognizer) {
        let panningPoint: PanningPoint = .cell
        let location = sender.location(in: nil)

        switch sender.state {
        case .began:
            currentPanningPoint = panningPoint
            firstTouchLocation = location
            lastTouchLocation = location
            willPanHandler?(panningPoint)

        case .changed:
            lastTouchLocation = location
            let length = lastTouchLocation.y - firstTouchLocation.y
            didPanCellHandler?(length)

        default:
            currentPanningPoint = nil
            didEndPanningHandler?(panningPoint)
        }
    }

    /// 🤔
    /// for EventScrollView.Editor.
    /// Editor wants to move cell by panning after detected long press cell.
    internal func simulateCellOverlayViewPanning(_ sender: UIGestureRecognizer) {
        didPanCellOverlayView(sender)
    }

    @objc private func didPanKnobView(_ sender: UIPanGestureRecognizer) {
        guard sender.view == topKnobView || sender.view == bottomKnobView else { fatalError() }
        let panningPoint: PanningPoint = sender.view == topKnobView ? .topKnob : .bottomKnob
        guard currentPanningPoint == nil || currentPanningPoint == panningPoint
            else { fatalError("Restrict (cell, top, bottom)PanGestureRecognizer.isEnabled") }
        let location = sender.location(in: nil)

        switch sender.state {
        case .began:
            currentPanningPoint = panningPoint
            // top and bottom may overlap, so bring touched knob and timeView to front
            if panningPoint == .topKnob {
                timeRangeView.bringStartViewToFront()
                topKnobView.superview!.insertSubview(topKnobView, aboveSubview: bottomKnobView)
            } else if panningPoint == .bottomKnob {
                timeRangeView.bringEndViewToFront()
                bottomKnobView.superview!.insertSubview(bottomKnobView, aboveSubview: topKnobView)
            }

            firstTouchLocation = location
            lastTouchLocation = location
            willPanHandler?(panningPoint)

        case .changed:
            lastTouchLocation = location
            let length = lastTouchLocation.y - firstTouchLocation.y
            didPanKnobHandler?(panningPoint, length)

        default:
            currentPanningPoint = nil
            didEndPanningHandler?(panningPoint)
        }
    }
    
    @objc private func eventCellDidSetEvent(_ notification: Notification) {
        guard let eventCell = notification.object as? EventCell, eventCell == editingCell else { return }
        updateTimeLabels()
    }
}

extension EditingOverlayView {
    enum PanningPoint {
        case cell
        case topKnob
        case bottomKnob
    }
}
