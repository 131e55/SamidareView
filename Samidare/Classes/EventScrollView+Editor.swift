//
//  EventScrollView+Editor.swift
//  Samidare
//
//  Created by Keisuke Kawamura on 2018/10/27.
//

import UIKit

internal extension EventScrollView {

    final class Editor: NSObject {

        private enum Edge {
            case top
            case bottom
            case both
        }

        private weak var eventScrollView: EventScrollView?
        private let heavyImpactFeedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)
        private let lightImpactFeedbackGenerator = UIImpactFeedbackGenerator(style: .light)
        private let errorFeedbackGenerator = UINotificationFeedbackGenerator()
        private var addedLongPressGestureRecognizers: [UILongPressGestureRecognizer] = []
        private var eventScrollViewTapGestureRecognizer: UITapGestureRecognizer?

        /// Current editing EventCell.
        private weak var editingCell: EventCell?
        /// Copy of editingCell.event at begin editing such as 'top knob panning', 'bottom knob panning' and 'cell panning'.
        private var eventAtBeginEditing: Event?
        /// Copy of editingCell.frame at begin editing such as 'top knob panning', 'bottom knob panning' and 'cell panning'.
        private var cellFrameAtBeginEditing: CGRect?

        private weak var snapshotView: UIView?
        private weak var editingOverlayView: EditingOverlayView?

        /// Tells editing has begun.
        internal var didBeginEditingHandler: ((_ cell: EventCell) -> Void)?
        internal var didEditHandler: ((_ cell: EventCell) -> Void)?
        internal var didEndEditingHandler: ((_ cell: EventCell) -> Void)?

        override init() {
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(eventCellWillRemoveFromSuperview),
                                                   name: EventCell.willRemoveFromSuperviewNotification, object: nil)
        }
        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Setup Editor
        ///
        /// - Parameters:
        ///   - eventScrollView: EventScrollView to apply Editor function.
        internal func setup(eventScrollView: EventScrollView, displaysOriginalCell: Bool = true) {
            self.eventScrollView = eventScrollView
        }

        /// Editor observes long-press on EventCell.
        internal func observe(cell: EventCell) {
            let cellRecognizers = cell.gestureRecognizers?.compactMap({ $0 as? UILongPressGestureRecognizer }) ?? []
            guard cellRecognizers.contains(where: { recognizer -> Bool in
                return addedLongPressGestureRecognizers.contains(recognizer)
            }) == false else { return }

            addedLongPressGestureRecognizers = addedLongPressGestureRecognizers.filter({ $0.view != cell })
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(eventCellWasLongPressed))
            cell.addGestureRecognizer(recognizer)
            addedLongPressGestureRecognizers.append(recognizer)
        }

        internal func unobserve(cell: EventCell) {
            let cellRecognizers = cell.gestureRecognizers?.compactMap({ $0 as? UILongPressGestureRecognizer }) ?? []
            guard let recognizer = cellRecognizers.first(where: { recognizer in
                return addedLongPressGestureRecognizers.contains(recognizer)
            }) else { return }

            cell.removeGestureRecognizer(recognizer)
            addedLongPressGestureRecognizers = addedLongPressGestureRecognizers.filter({ $0.view != cell })
        }

        internal func beginEditing(for cell: EventCell, displaysOriginalCell: Bool = true) {
            guard let scrollView = eventScrollView else { fatalError("Call setup() first.") }

            heavyImpactFeedbackGenerator.prepare()
            lightImpactFeedbackGenerator.prepare()

            endEditing()
            editingCell = cell
            
            if displaysOriginalCell {
                let snapshot = cell.snapshotView()
                snapshot.frame = cell.frame
                snapshot.alpha = 0.25
                scrollView.insertSubview(snapshot, belowSubview: cell)
                snapshotView = snapshot
            }

            let overlayView = EditingOverlayView(cell: cell)
            overlayView.willPanHandler = { [weak self] _ in
                guard let self = self, let cell = self.editingCell else { return }
                self.eventAtBeginEditing = cell.event
                self.cellFrameAtBeginEditing = cell.frame
            }
            overlayView.didPanCellHandler = { [weak self] length in
                guard let self = self else { return }
                self.edit(edge: .both, panningLength: length)
            }
            overlayView.didPanKnobHandler = { [weak self] panningPoint, length in
                guard let self = self else { return }
                self.edit(edge: panningPoint == .topKnob ? .top : .bottom, panningLength: length)
            }
            overlayView.didEndPanningHandler = { [weak self] _ in
                guard let self = self, let cell = self.editingCell else { return }
                self.eventAtBeginEditing = cell.event
                self.snapCellFrame()
                self.cellFrameAtBeginEditing = cell.frame
            }
            scrollView.addSubview(overlayView)
            editingOverlayView = overlayView
            updateTimeRangeViewPosition()

            let recognizer = UITapGestureRecognizer(target: self, action: #selector(eventScrollViewWasTapped))
            recognizer.delegate = self
            scrollView.addGestureRecognizer(recognizer)
            eventScrollViewTapGestureRecognizer = recognizer

            NotificationCenter.default.addObserver(self, selector: #selector(eventScrollViewDidScroll),
                                                   name: EventScrollView.didScrollNotification,
                                                   object: scrollView)
            NotificationCenter.default.addObserver(self, selector: #selector(eventScrollViewDidEndScroll),
                                                   name: EventScrollView.didEndScrollNotification,
                                                   object: scrollView)
            heavyImpactFeedbackGenerator.impactOccurred()
            didBeginEditingHandler?(cell)
        }

        private func endEditing() {
            snapshotView?.removeFromSuperview()
            editingOverlayView?.removeFromSuperview()
            if let recognizer = eventScrollViewTapGestureRecognizer {
                eventScrollView?.removeGestureRecognizer(recognizer)
            }
            NotificationCenter.default.removeObserver(self, name: EventScrollView.didScrollNotification, object: nil)
            
            if let editingCell = editingCell {
                didEndEditingHandler?(editingCell)
            }
            editingCell = nil
        }

        private func edit(edge: Edge, panningLength: CGFloat) {
            guard let layoutData = eventScrollView?.layoutData,
                let scrollView = eventScrollView,
                let cell = editingCell,
                let eventAtBeginEditing = eventAtBeginEditing,
                let cellFrameAtBeginEditing = cellFrameAtBeginEditing,
                var newFrame = self.cellFrameAtBeginEditing
                else { return }
            let heightUnit = layoutData.layoutUnit.heightUnit
            var deltaHeight = panningLength
            let deltaHeightSign = deltaHeight != 0 ? deltaHeight / abs(deltaHeight) : 1

            switch edge {
            case .top:
                // if deltaHeight is negative, the frame will be expanded to top-side.
                // if deltaHeight is positive, the frame will be contracted to bottom-side.

                // Guard minimum height
                if newFrame.size.height - deltaHeight < heightUnit {
                    deltaHeight = deltaHeightSign * (newFrame.size.height - heightUnit)
                }
                // Guard minimum origin.minY
                if newFrame.origin.y + deltaHeight < 0 {
                    deltaHeight = -newFrame.origin.y
                }
                newFrame.origin.y += deltaHeight
                newFrame.size.height -= deltaHeight
                
            case .bottom:
                // if the height is positive, the frame will be expanded to bottom-side.
                // if the height is negative, the frame will be contracted to top-side.

                // Guard minimum height
                if newFrame.size.height + deltaHeight < heightUnit {
                    deltaHeight = deltaHeightSign * (newFrame.size.height - heightUnit)
                }
                // Guard maximum origin.maxY
                if newFrame.maxY + deltaHeight > scrollView.contentSize.height - TimeCell.preferredFont.lineHeight / 2 {
                    deltaHeight = scrollView.contentSize.height - TimeCell.preferredFont.lineHeight / 2 - newFrame.maxY
                }
                newFrame.size.height += deltaHeight

            case .both:
                var deltaY = panningLength
                
                // Guard minimum origin.minY
                if newFrame.origin.y + deltaY < 0 {
                    deltaY = -newFrame.origin.y
                }
                // Guard maximum origin.maxY
                if newFrame.maxY + deltaY > scrollView.contentSize.height - TimeCell.preferredFont.lineHeight / 2 {
                    deltaY = scrollView.contentSize.height - TimeCell.preferredFont.lineHeight / 2 - newFrame.maxY
                }
                
                newFrame.origin.y += deltaY
            }
            cell.frame = newFrame
            
            //
            // Calc new Event start time
            //
            // positive: start time will be late.
            // negative: start time will be early.
            let deltaStartMinutes = layoutData.roundedMinutes(from: (newFrame.minY - cellFrameAtBeginEditing.minY))
            let totalMinutes = layoutData.roundedMinutes(from: newFrame.height)
            let newStartDate = eventAtBeginEditing.start.addingTimeInterval(TimeInterval(deltaStartMinutes * 60))
            let newEndDate = newStartDate.addingTimeInterval(TimeInterval(totalMinutes * 60))

            if cell.event.start != newStartDate || cell.event.end != newEndDate {
                var newEvent = cell.event
                newEvent.time = newStartDate ... newEndDate
                cell.configure(event: newEvent)

                lightImpactFeedbackGenerator.impactOccurred()
                didEditHandler?(cell)
            }
        }
        
        private func snapCellFrame() {
            guard let layoutData = eventScrollView?.layoutData, let cell = editingCell else { return }
            let y = layoutData.roundedDistanceOfTimeRangeStart(to: cell.event.start)
            let height = layoutData.roundedHeight(from: cell.event.durationInSeconds)
            let snappedFrame = CGRect(x: cell.frame.minX,
                                      y: y,
                                      width: cell.frame.width,
                                      height: height)
            cell.frame = snappedFrame
        }

        @objc private func eventCellWasLongPressed(_ sender: UILongPressGestureRecognizer) {
            guard let cell = sender.view as? EventCell else { return }

            if sender.state == .began {
                if cell.event.isEditable {
                    beginEditing(for: cell)
                } else {
                    errorFeedbackGenerator.notificationOccurred(.error)
                }
            }

            if let overlayView = editingOverlayView {
                overlayView.simulateCellOverlayViewPanning(sender)
            }
        }
        
        @objc private func eventScrollViewWasTapped(_ sender: UITapGestureRecognizer) {
            guard let scrollView = eventScrollView, let cell = editingCell else { return }
            // When touch point that not in cell.frame, end editing.
            let cellFrameInScrollView = cell.convert(cell.bounds, to: scrollView)
            let touchPointInScrollView = sender.location(in: scrollView)
            if cellFrameInScrollView.contains(touchPointInScrollView) == false {
                endEditing()
            }
        }
        
        @objc private func eventScrollViewDidScroll(_ notification: Notification) {
            eventScrollViewTapGestureRecognizer?.isEnabled = false
            updateTimeRangeViewPosition()
        }
        
        @objc private func eventScrollViewDidEndScroll(_ notification: Notification) {
            eventScrollViewTapGestureRecognizer?.isEnabled = true
        }
        
        private func updateTimeRangeViewPosition() {
            guard  let scrollView = eventScrollView, let cell = editingCell,
                let overlayView = editingOverlayView else { return }
            let cellXInScrollView = cell.frame.minX - scrollView.contentOffset.x - scrollView.contentInset.left
            overlayView.setTimeRangeViewPosition(toRight: cellXInScrollView <= overlayView.timeInfoWidth)
        }

        @objc private func eventCellWillRemoveFromSuperview(_ notification: Notification) {
            guard let cell = notification.object as? EventCell else { return }

            if cell == editingCell {
                endEditing()
            }

            unobserve(cell: cell)
        }
    }
}

// MARK: - UIGestureRecognizerDelegate
extension EventScrollView.Editor: UIGestureRecognizerDelegate {
    internal func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == eventScrollViewTapGestureRecognizer {
            return true
        }
        return false
    }
}

extension EventScrollView.Editor {
    /// 🤔
    /// for EventScrollView.Creator.
    /// Creator wants to expand cell height by panning after detected long press on EventScrollView.
    internal func simulateBottomKnobPanning(_ recognizer: UIGestureRecognizer) {
        guard let editingOverlayView = editingOverlayView else { fatalError("Editor is not editing.") }
        editingOverlayView.simulateBottomKnobPanning(recognizer)
    }
}
