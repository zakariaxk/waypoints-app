package main

// curatedMake is one make the catalog covers. VPICID is the vPIC Make_ID; zero means the
// make is not in vPIC under its own name (Scion is filed under Toyota there), so its models
// come from EPA only. Bike makes take only vPIC "Motorcycle" models and have no EPA data.
type curatedMake struct {
	Name   string // display name
	VPICID int
	Bike   bool
	EPA    []string // EPA make spellings when they differ from Name
}

// About 90 passenger and motorcycle makes sold in the US (plan section 11.1).
var curatedMakes = []curatedMake{
	{Name: "Acura", VPICID: 475},
	{Name: "Alfa Romeo", VPICID: 493},
	{Name: "AMC", VPICID: 1124, EPA: []string{"AM General", "American Motors Corporation"}},
	{Name: "Aston Martin", VPICID: 440},
	{Name: "Audi", VPICID: 582},
	{Name: "Bentley", VPICID: 583},
	{Name: "BMW", VPICID: 452, EPA: []string{"BMW", "BMW Alpina"}},
	{Name: "Bugatti", VPICID: 454},
	{Name: "Buick", VPICID: 468},
	{Name: "Cadillac", VPICID: 469},
	{Name: "Chevrolet", VPICID: 467},
	{Name: "Chrysler", VPICID: 477},
	{Name: "Daewoo", VPICID: 1077},
	{Name: "Daihatsu", VPICID: 847},
	{Name: "Datsun", VPICID: 5657},
	{Name: "DeLorean", VPICID: 13022, EPA: []string{"DeLorean Motor Company"}},
	{Name: "Dodge", VPICID: 476},
	{Name: "Eagle", VPICID: 2408},
	{Name: "Ferrari", VPICID: 603},
	{Name: "Fiat", VPICID: 492},
	{Name: "Fisker", VPICID: 11856},
	{Name: "Ford", VPICID: 460},
	{Name: "Genesis", VPICID: 5083},
	{Name: "Geo", VPICID: 1146},
	{Name: "GMC", VPICID: 472},
	{Name: "Honda", VPICID: 474},
	{Name: "Hummer", VPICID: 951},
	{Name: "Hyundai", VPICID: 498},
	{Name: "Infiniti", VPICID: 480},
	{Name: "Ineos", VPICID: 12360},
	{Name: "Isuzu", VPICID: 542},
	{Name: "Jaguar", VPICID: 442},
	{Name: "Jeep", VPICID: 483},
	{Name: "Karma", VPICID: 5122},
	{Name: "Kia", VPICID: 499},
	{Name: "Koenigsegg", VPICID: 1896},
	{Name: "Lamborghini", VPICID: 502},
	{Name: "Land Rover", VPICID: 444},
	{Name: "Lexus", VPICID: 515},
	{Name: "Lincoln", VPICID: 464},
	{Name: "Lotus", VPICID: 466},
	{Name: "Lucid", VPICID: 10919},
	{Name: "Maserati", VPICID: 443},
	{Name: "Maybach", VPICID: 533},
	{Name: "Mazda", VPICID: 473},
	{Name: "McLaren", VPICID: 2236, EPA: []string{"McLaren Automotive"}},
	{Name: "Mercedes-Benz", VPICID: 449},
	{Name: "Mercury", VPICID: 465},
	{Name: "Merkur", VPICID: 5468},
	{Name: "Mini", VPICID: 456, EPA: []string{"MINI"}},
	{Name: "Mitsubishi", VPICID: 481},
	{Name: "Nissan", VPICID: 478},
	{Name: "Oldsmobile", VPICID: 4162},
	{Name: "Pagani", VPICID: 4767},
	{Name: "Panoz", VPICID: 4220, EPA: []string{"Panoz Auto-Development"}},
	{Name: "Peugeot", VPICID: 5554},
	{Name: "Plymouth", VPICID: 2409},
	{Name: "Polestar", VPICID: 10224},
	{Name: "Pontiac", VPICID: 536},
	{Name: "Porsche", VPICID: 584},
	{Name: "Ram", VPICID: 496},
	{Name: "Rivian", VPICID: 10887},
	{Name: "Rolls-Royce", VPICID: 445},
	{Name: "Rover", VPICID: 10652},
	{Name: "Saab", VPICID: 572},
	{Name: "Saleen", VPICID: 4355},
	{Name: "Saturn", VPICID: 1056},
	{Name: "Scion", VPICID: 0},
	{Name: "Scout", VPICID: 12642},
	{Name: "Shelby", VPICID: 11832},
	{Name: "Smart", VPICID: 504, EPA: []string{"smart"}},
	{Name: "Spyker", VPICID: 3766, EPA: []string{"Spyker"}},
	{Name: "Sterling", VPICID: 0},
	{Name: "Subaru", VPICID: 523},
	{Name: "Suzuki", VPICID: 509},
	{Name: "Tesla", VPICID: 441},
	{Name: "Toyota", VPICID: 448},
	{Name: "VinFast", VPICID: 11366},
	{Name: "Volkswagen", VPICID: 482},
	{Name: "Volvo", VPICID: 485},
	{Name: "Yugo", VPICID: 5553},

	{Name: "Aprilia", VPICID: 845, Bike: true},
	{Name: "Ducati", VPICID: 568, Bike: true},
	{Name: "Harley-Davidson", VPICID: 3888, Bike: true},
	{Name: "Indian", VPICID: 1768, Bike: true},
	{Name: "Kawasaki", VPICID: 510, Bike: true},
	{Name: "KTM", VPICID: 596, Bike: true},
	{Name: "MV Agusta", VPICID: 2536, Bike: true},
	{Name: "Triumph", VPICID: 565, Bike: true},
	{Name: "Yamaha", VPICID: 564, Bike: true},
}

// popularMakes seeds the picker's "Popular" section until the app has its own counts.
var popularMakes = []string{
	"Ford", "Chevrolet", "Toyota", "Honda", "Subaru", "BMW",
	"Nissan", "Dodge", "Volkswagen", "Mazda", "Jeep", "Porsche",
}

const (
	firstYear = 1981
	lastYear  = 2027
)
