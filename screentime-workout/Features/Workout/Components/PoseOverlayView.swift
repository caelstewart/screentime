//
//  PoseOverlayView.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import SwiftUI

struct PoseOverlayView: View {
    let pose: DetectedPose?
    let lineColor: Color
    let jointColor: Color
    let lineWidth: CGFloat
    let jointRadius: CGFloat
    
    init(
        pose: DetectedPose?,
        lineColor: Color = Theme.Colors.skeleton,
        jointColor: Color = Theme.Colors.jointDot,
        lineWidth: CGFloat = 4,
        jointRadius: CGFloat = 6
    ) {
        self.pose = pose
        self.lineColor = lineColor
        self.jointColor = jointColor
        self.lineWidth = lineWidth
        self.jointRadius = jointRadius
    }
    
    var body: some View {
        GeometryReader { geometry in
            if let pose {
                Canvas { context, size in
                    // Draw connections
                    for connection in DetectedPose.skeletonConnections {
                        if let from = pose.joint(connection.0),
                           let to = pose.joint(connection.1) {
                            let fromPoint = CGPoint(
                                x: from.position.x * size.width,
                                y: from.position.y * size.height
                            )
                            let toPoint = CGPoint(
                                x: to.position.x * size.width,
                                y: to.position.y * size.height
                            )
                            
                            var path = Path()
                            path.move(to: fromPoint)
                            path.addLine(to: toPoint)
                            
                            // Outer glow (Cyan)
                            context.stroke(
                                path,
                                with: .color(lineColor.opacity(0.5)),
                                style: StrokeStyle(lineWidth: lineWidth + 6, lineCap: .round)
                            )
                            
                            // Inner solid line (White/Cyan)
                            context.stroke(
                                path,
                                with: .color(lineColor),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                            )
                        }
                    }
                    
                    // Draw joints
                    for (_, joint) in pose.joints {
                        let point = CGPoint(
                            x: joint.position.x * size.width,
                            y: joint.position.y * size.height
                        )
                        
                        // Joint circle
                        let jointRect = CGRect(
                            x: point.x - jointRadius,
                            y: point.y - jointRadius,
                            width: jointRadius * 2,
                            height: jointRadius * 2
                        )
                        context.fill(
                            Circle().path(in: jointRect),
                            with: .color(jointColor)
                        )
                    }
                }
            }
        }
    }
}
