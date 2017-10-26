import { Component } from '@angular/core';
import { NavController } from 'ionic-angular';

@Component({
  selector: 'page-designer',
  templateUrl: 'designer.html'
})
export class DesignerPage {
  cars: Object[];

  constructor(public navController: NavController) {
    this.cars = [{
      name: 'Two Bedroom, Two Bathroom',
      image: 'home_1.jpg',
      zoom: 'cover'
    }, {
      name: 'Three Bed, Three Bathroom',
      image: 'home_2.jpg',
      zoom: 'cover'
    }, {
      name: 'Four Bed, Three Bathroom',
      image: 'home_3.jpg',
      zoom: 'cover'
    }]
  }

}
