Simple Build Agent (in Perl)
============================

Compares a local and remote code repo (SVN for now), and if changes are detected then it can launch build steps using one or more saved configurations (eg. to build different versions of the same code). Each configuration can have up to 5 steps: clean, build, deploy (package), distribute, and finish (final step). All steps are optional. It can also be forced to launch builds, regardless of repo status.

Full documentation here: http://mpaperno.github.io/SBA/


Copyright (c) 2014 by Maxim Paperno. All rights reserved.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
 
