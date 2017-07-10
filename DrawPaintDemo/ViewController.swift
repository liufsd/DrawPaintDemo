//
//  ViewController.swift
//  DrawPaintDemo
//
//  Created by liupeng on 10/07/2017.
//  Copyright © 2017 liupeng. All rights reserved.
//

import UIKit

class ViewController: UIViewController {
   let mercurialPaint = MercurialPaint(frame: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        view.backgroundColor = UIColor.black
        
        view.addSubview(mercurialPaint)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }


}

